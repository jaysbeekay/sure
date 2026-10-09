require "test_helper"

class Loan::CurrentMinimumPaymentTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
  end

  # #15's acceptance criterion, taken from a real lender letter. Both figures
  # reproduce the letter to the cent as stated in the issue; the residual
  # against the LENDER's own printed number is +$0.29 and -$0.75.
  #
  # The +/-$1.00 tolerance is the lender's rounding, not ours: a lender quotes a
  # repayment rounded to its own convention and may size the final payment to
  # absorb the difference. Tightening this to the cent would assert that our
  # rounding matches theirs, which the letter gives no basis for. Loosening it
  # past a dollar would stop the test noticing a wrong term or a wrong rate --
  # one month of term error moves this figure by roughly $6.
  test "the level payment reproduces the lender letter within one dollar" do
    [
      { rate: "6.18", months: 277, lender: "2719.04" },
      { rate: "5.93", months: 279, lender: "2651.07" }
    ].each do |example|
      computed = Loan::AmortizationMath.level_payment(
        balance: BigDecimal("400762.12"),
        monthly_rate: Loan.monthly_rate(example[:rate]),
        remaining_payments: example[:months],
        currency_precision: 2
      )

      assert_in_delta BigDecimal(example[:lender]), computed, BigDecimal("1.00"),
        "#{example[:rate]}% over #{example[:months]} months must match the lender letter"
    end
  end

  # #392. The lender sets the minimum on the SCHEDULED balance -- the contract
  # re-amortised at each recorded rate change -- not on what the borrower
  # actually owes. The figure is the schedule row in force: the payment of the
  # first contracted period still to come.
  #
  # The synthetic loan from the issue: $400,000 over 360 months at 5.50%, moving
  # to 6.43% on payment 13's date, 50 payments made, and $40,000 paid ahead.
  test "a variable loan quotes the schedule's payment for the current period, not the actual-balance figure" do
    loan = issue_392_loan

    row = loan.amortization_schedule.payments.find { |p| p[:payment_number] == 51 }
    assert_equal ISSUE_392_AS_OF.next_month.change(day: 15), row[:payment_date], "precondition: payment 51 is next"

    assert_equal Money.new(row[:payment_amount], "USD"), loan.current_minimum_payment(as_of: ISSUE_392_AS_OF)
    assert_in_delta BigDecimal("2504.44"), row[:payment_amount], BigDecimal("2.00"),
      "the issue's figure was computed with monthly accrual; the fork accrues daily, which moves it by cents to dollars"
    assert_operator loan.current_minimum_payment(as_of: ISSUE_392_AS_OF).amount, :>,
      actual_balance_figure(loan) + BigDecimal("200"),
      "main quoted ~$2,239.58 here, re-amortising the actual balance; the lender's minimum is ~$265 higher"
  end

  test "the figure is the one the schedule re-amortised at the rate change" do
    loan = issue_392_loan
    schedule = loan.amortization_schedule.payments
    at_change = schedule.find { |p| p[:payment_number] == 13 }

    before_change = schedule.find { |p| p[:payment_number] == 12 }
    annuity = Loan::AmortizationMath.level_payment(
      balance: at_change[:beginning_balance],
      monthly_rate: Loan.monthly_rate("6.43"),
      remaining_payments: 348,
      currency_precision: 2
    )

    # Payment 13 is the resize: it differs from payment 12 and is (within the
    # engine's sizing of the straddled period, #184) the 6.43% annuity on the
    # scheduled balance. The figure quoted is that row's, to the cent.
    assert_not_equal before_change[:payment_amount], at_change[:payment_amount], "precondition: payment 13 is the resize"
    assert_in_delta annuity, at_change[:payment_amount], BigDecimal("5"), "precondition: payment 13 is the 6.43% annuity"
    assert_equal at_change[:payment_amount], loan.current_minimum_payment(as_of: ISSUE_392_AS_OF).amount
  end

  test "an offset does not change the current minimum repayment" do
    loan = issue_392_loan
    without = loan.current_minimum_payment(as_of: ISSUE_392_AS_OF)

    offset = @family.accounts.create!(name: "Offset", balance: 30_000, currency: "USD", accountable: Depository.new)
    loan.update!(offset_account_ids: [ offset.id ])
    loan.reload

    assert_operator loan.interest_bearing_balance.amount, :<, loan.account.balance, "precondition: the offset counts"
    assert_equal without, loan.current_minimum_payment(as_of: ISSUE_392_AS_OF)
  end

  test "paying further ahead does not change the current minimum repayment" do
    loan = issue_392_loan
    before = loan.current_minimum_payment(as_of: ISSUE_392_AS_OF)

    loan.account.update!(balance: loan.account.balance - 25_000)
    after = loan.reload.current_minimum_payment(as_of: ISSUE_392_AS_OF)

    assert_equal before, after
  end

  # The negative of the two above: if the figure ignored everything, they would
  # pass against a constant.
  test "a recorded rate change does change the current minimum repayment" do
    loan = issue_392_loan
    before = loan.current_minimum_payment(as_of: ISSUE_392_AS_OF)

    loan.add_variable_rate_change(Date.new(2025, 6, 15), 7.10)
    after = loan.reload.current_minimum_payment(as_of: ISSUE_392_AS_OF)

    assert_operator after, :>, before
  end

  # Both sides of the boundary, matching `remaining_payment_count`: a payment due
  # on `as_of` has been made.
  test "a payment due on as_of is behind it; the day before, it is the one in force" do
    loan = issue_392_loan
    rows = loan.amortization_schedule.payments
    change = rows.find { |p| p[:payment_number] == 13 }
    before_change = rows.find { |p| p[:payment_number] == 12 }

    # Payments 12 and 13 differ, so payment 12's date is the boundary that
    # discriminates: on it payment 12 has been made and 13 is in force; the day
    # before, 12 is still to come.
    assert_not_equal change[:payment_amount], before_change[:payment_amount], "precondition"
    assert_equal change[:payment_amount],
      loan.current_minimum_payment(as_of: before_change[:payment_date]).amount
    assert_equal before_change[:payment_amount],
      loan.current_minimum_payment(as_of: before_change[:payment_date] - 1.day).amount
  end

  test "before the first payment the figure is the first row's payment" do
    loan = issue_392_loan

    assert_equal loan.amortization_schedule.payments.first[:payment_amount],
      loan.current_minimum_payment(as_of: ISSUE_392_START).amount
  end

  test "a stale persisted schedule does not change the figure" do
    loan = issue_392_loan
    loan.ensure_amortization_schedule_current!
    before = loan.current_minimum_payment(as_of: ISSUE_392_AS_OF)
    assert loan.amortizations.exists?, "precondition: rows are persisted"

    loan.amortizations.update_all(payment_amount: 1)

    assert_equal before, loan.reload.current_minimum_payment(as_of: ISSUE_392_AS_OF)
  end

  test "a loan with no start date reads the schedule from its opening anchor" do
    account = @family.accounts.create!(
      name: "Anchored loan", balance: 300_000, currency: "USD",
      accountable: Loan.new(rate_type: "variable", interest_rate: 5.0, term_months: 240, initial_balance: 300_000)
    )
    account.entries.create!(
      name: "Opening", amount: 300_000, currency: "USD", date: Date.new(2024, 1, 10),
      entryable: Valuation.new(kind: "opening_anchor")
    )
    loan = account.loan.reload
    assert_nil loan.start_date, "precondition"

    as_of = Date.new(2025, 3, 20)
    row = loan.amortization_schedule.payments.find { |p| p[:payment_date] > as_of }

    assert_equal Date.new(2025, 4, 10), row[:payment_date]
    assert_equal row[:payment_amount], loan.current_minimum_payment(as_of: as_of).amount
  end

  test "a fixed-rate loan is unaffected and still quotes the contracted payment" do
    loan = variable_loan(balance: 400_762.12, rate: 6.18, term_months: 360, months_elapsed: 83)
    loan.update!(rate_type: "fixed")

    assert_equal loan.amortization_schedule.monthly_payment, loan.current_minimum_payment
  end

  # A loan past its maturity has no payments left to spread a balance over, so
  # there is no repayment to quote. Returning a figure here would be inventing
  # a term the loan does not have.
  test "no payments remaining yields no figure rather than a divide by zero" do
    loan = variable_loan(balance: 400_762.12, rate: 6.18, term_months: 12, months_elapsed: 24)

    assert_equal 0, loan.amortization_schedule.remaining_payment_count
    assert_nil loan.current_minimum_payment
  end

  # A fixed loan quotes its contracted repayment for every day of its term --
  # #15 changes nothing about that, and this asserts it.
  test "a live fixed loan still quotes the contracted payment" do
    loan = variable_loan(balance: 400_762.12, rate: 6.18, term_months: 360, months_elapsed: 83)
    loan.update!(rate_type: "fixed")

    assert_equal loan.reload.amortization_schedule.monthly_payment,
      loan.current_minimum_payment
  end

  # CodeRabbit, #79. Past maturity there are no payments left to spread a
  # balance over, so there is no repayment to quote -- and that is as true of a
  # fixed loan as a variable one. The fixed branch used to return before the
  # maturity check, so a matured fixed loan quoted its contracted repayment
  # while a matured variable loan beside it said "Unknown".
  test "a matured fixed loan has no figure either" do
    loan = variable_loan(balance: 400_762.12, rate: 6.18, term_months: 12, months_elapsed: 24)
    loan.update!(rate_type: "fixed")
    loan.reload

    assert_equal 0, loan.amortization_schedule.remaining_payment_count
    assert loan.amortization_schedule.monthly_payment.amount.positive?,
      "the contracted payment must still be a positive figure, or this proves nothing"
    assert_nil loan.current_minimum_payment,
      "a matured loan has no repayment to quote, whatever its rate type"
  end

  private

    ISSUE_392_START = Date.new(2022, 1, 15)
    # After payment 50 (2026-03-15) and before payment 51.
    ISSUE_392_AS_OF = Date.new(2026, 3, 20)

    # The loan from #392, $40,000 ahead of its schedule.
    def issue_392_loan
      account = @family.accounts.create!(
        name: "Issue 392 loan", balance: 400_000, currency: "USD",
        accountable: Loan.new(
          rate_type: "variable", interest_rate: 5.5, term_months: 360,
          initial_balance: 400_000, start_date: ISSUE_392_START,
          variable_rate_schedule: { "2023-02-15" => "6.43" }
        )
      )
      account.entries.create!(
        name: "Opening", amount: 400_000, currency: "USD", date: ISSUE_392_START,
        entryable: Valuation.new(kind: "opening_anchor")
      )
      loan = account.loan.reload
      scheduled = loan.amortization_schedule.payments.find { |p| p[:payment_number] == 50 }[:ending_balance]
      account.update!(balance: scheduled - 40_000)
      loan.reload
    end

    # What main quoted: the actual balance net of offset, at today's rate, over
    # the payments left.
    def actual_balance_figure(loan)
      Loan::AmortizationMath.level_payment(
        balance: loan.interest_bearing_balance.amount,
        monthly_rate: Loan.monthly_rate(loan.current_variable_rate(ISSUE_392_AS_OF)),
        remaining_payments: loan.amortization_schedule.remaining_payment_count(as_of: ISSUE_392_AS_OF),
        currency_precision: 2
      )
    end

    def variable_loan(balance:, rate:, term_months:, months_elapsed:)
      account = @family.accounts.create!(
        name: "Minimum Payment Loan #{SecureRandom.hex(4)}",
        balance: balance,
        currency: "USD",
        accountable: Loan.new(
          rate_type: "variable",
          interest_rate: rate,
          term_months: term_months,
          initial_balance: balance,
          start_date: Date.current - months_elapsed.months
        )
      )
      account.loan
    end
end
