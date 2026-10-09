require "test_helper"

# #100, decision 1 (owner, 2026-09-08): "The projection pays the schedule's
# repayment, against the actual balance." A variable loan ahead of schedule
# keeps paying what the contract currently requires and so clears EARLIER; it
# must not hold the contracted FIRST payment, which every rate change since
# has left behind. Before this the projection carried
# AmortizationSchedule#monthly_payment -- the payment at origination -- across
# every period.
class Loan::ScheduledProjectionTest < ActiveSupport::TestCase
  AS_OF = Date.new(2026, 3, 20)

  test "the projection pays the schedule's repayment in force, not the first contracted one" do
    loan = loan_with(balance_offset: -40_000)
    first = projection(loan).payments.first
    schedule_row = schedule_row_on(loan, first[:payment_date])

    assert_not_equal loan.amortization_schedule.monthly_payment.amount, schedule_row[:payment_amount],
      "precondition: the rate change has moved the scheduled repayment"
    assert_equal schedule_row[:payment_amount], first[:payment_amount]
  end

  test "a future recorded rate change resizes the projected repayment where the schedule does" do
    loan = loan_with(balance_offset: -40_000, changes: { "2027-06-15" => "7.25" })
    payments = projection(loan).payments
    on_change = payments.find { |row| row[:payment_date] == Date.new(2027, 6, 15) }
    before = payments[payments.index(on_change) - 1]

    assert_not_equal before[:payment_amount], on_change[:payment_amount], "the repayment must move at the change"
    assert_equal schedule_row_on(loan, on_change[:payment_date])[:payment_amount], on_change[:payment_amount]
  end

  test "a variable loan ahead of schedule clears before the schedule does, with no extra" do
    loan = loan_with(balance_offset: -40_000)
    projected = projection(loan)

    assert projected.applicable?
    assert_operator projected.payoff_date, :<, loan.amortization_schedule.payoff_date
    assert_operator projected.months_saved, :>, 0
  end

  # The settlement row squares the contract's own rounding and drift; it is not
  # a repayment the contract asks of a loan that is behind. Past it -- and past
  # maturity, where a loan behind schedule still owes -- the last level
  # repayment holds, as the held projection always did.
  test "a loan behind schedule holds the last level repayment past maturity" do
    loan = loan_with(balance_offset: 25_000)
    schedule = loan.amortization_schedule.payments
    payments = projection(loan).payments
    past_maturity = payments.select { |row| row[:payment_date] > schedule.last[:payment_date] }

    assert projection(loan).applicable?
    assert past_maturity.length > 1, "precondition: the loan runs past its maturity"
    assert_equal [ schedule[-2][:payment_amount] ], past_maturity[0..-2].map { |row| row[:payment_amount] }.uniq
  end

  test "an extra repayment rides on top of the scheduled one" do
    loan = loan_with(balance_offset: -40_000)
    extra = Money.new(250, "USD")
    plain = projection(loan).payments.first
    with_extra = Loan::PayoffProjection.new(loan, extra_payment: extra, as_of: AS_OF).payments.first

    assert_equal plain[:payment_amount] + 250, with_extra[:payment_amount]
  end

  # The negative: on a fixed loan every scheduled row is the contracted
  # repayment, so the projection is byte-identical to the held one.
  test "a fixed loan projects exactly as the held repayment did" do
    loan = loan_with(balance_offset: -40_000, rate_type: "fixed", changes: {})

    assert_equal Loan::PayoffProjection.new(loan, payment_strategy: :hold, as_of: AS_OF).payments,
      projection(loan).payments
  end

  test "the modelled monthly payment is the one in force now" do
    loan = loan_with(balance_offset: -40_000)

    assert_equal Money.new(projection(loan).payments.first[:payment_amount], "USD"), projection(loan).monthly_payment
  end

  private

    def projection(loan)
      Loan::PayoffProjection.new(loan, as_of: AS_OF)
    end

    def schedule_row_on(loan, date)
      loan.amortization_schedule.payments.find { |row| row[:payment_date] == date }
    end

    # $400,000 from 2022-01-15 at 5.50%, moving to 6.43% at payment 13 (#392's
    # loan). `balance_offset` moves the recorded balance off the scheduled
    # balance after payment 50: negative is ahead of schedule.
    def loan_with(balance_offset:, rate_type: "variable", changes: {})
      start = Date.new(2022, 1, 15)
      account = families(:dylan_family).accounts.create!(
        name: "Scheduled projection #{SecureRandom.hex(3)}", balance: 400_000, currency: "USD",
        accountable: Loan.new(
          rate_type: rate_type, interest_rate: 5.5, term_months: 360, initial_balance: 400_000,
          start_date: start, day_count_convention: "actual_365",
          variable_rate_schedule: rate_type == "fixed" ? {} : { "2023-02-15" => "6.43" }.merge(changes)
        )
      )
      account.entries.create!(
        name: "Opening", amount: 400_000, currency: "USD", date: start,
        entryable: Valuation.new(kind: "opening_anchor")
      )
      loan = account.loan.reload
      scheduled = loan.amortization_schedule.payments.find { |row| row[:payment_number] == 50 }[:ending_balance]
      account.update!(balance: scheduled + balance_offset)
      loan.reload
    end
end
