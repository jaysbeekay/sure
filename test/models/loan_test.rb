require "test_helper"

class LoanTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  # Leverage is what the down payment is FOR: 80,000 borrowed against 20,000 put
  # in is 4x, and the same loan against 5,000 is 16x. Bands are read off the
  # ratio rather than stored, so a loan re-read after an edit cannot disagree
  # with its own figure.
  test "leverage is the borrowed amount over the down payment" do
    loan = build_loan_account(balance: 80_000, down_payment: 20_000).loan

    assert_in_delta 4.0, loan.initial_leverage_ratio, 0.001
    assert_equal :conservative, loan.leverage_band, "4x sits on the conservative boundary"

    loan.down_payment = 5_000
    assert_in_delta 16.0, loan.initial_leverage_ratio, 0.001
    assert_equal :high, loan.leverage_band
  end

  test "a moderate loan lands in the middle band" do
    loan = build_loan_account(balance: 80_000, down_payment: 16_000).loan

    assert_in_delta 5.0, loan.initial_leverage_ratio, 0.001
    assert_equal :moderate, loan.leverage_band
  end

  # No deposit recorded is not a deposit of zero: a loan nobody has told us
  # about is not infinitely leveraged, and a view must be able to tell the two
  # apart to decide whether to show the figure at all.
  test "a loan with no down payment recorded has no leverage figure" do
    loan = build_loan_account(balance: 80_000, down_payment: nil).loan

    assert_nil loan.initial_leverage_ratio
    assert_nil loan.leverage_band

    loan.down_payment = 0
    assert_nil loan.initial_leverage_ratio, "zero is not a deposit either"
  end

  # Imports can open a loan at a negative valuation. That is no amount borrowed
  # to measure a deposit against, and a ratio from it has no band to name.
  test "a negative opening balance has no leverage figure" do
    loan = loans(:one)
    loan.down_payment = 100_000
    loan.stubs(:original_balance).returns(Money.new(-500_000, "USD"))

    assert_nil loan.initial_leverage_ratio
    assert_nil loan.leverage_band
  end

  test "rejects a negative down payment or insurance rate" do
    loan = Loan.new(down_payment: -1, insurance_rate: -1, insurance_rate_type: "nonsense")

    assert_not loan.valid?
    assert_includes loan.errors[:down_payment], "must be greater than or equal to 0"
    assert_includes loan.errors[:insurance_rate], "must be greater than or equal to 0"
    assert_includes loan.errors[:insurance_rate_type], "is not included in the list"
  end

  # An imported loan is the case where what was borrowed and what has been seen
  # are different numbers. Plaid sends `origination_principal_amount`, which
  # lands in `initial_balance`; the first valuation the account carries is
  # whatever the balance was on the day it was linked, years of repayments in.
  #
  # 20,000 borrowed, 10,000 outstanding, 5,000 deposit, a level-term policy at
  # 0.36% a year. Every figure below was measured against the 10,000 before
  # this: the schedule amortised half a loan, the borrower had repaid "none" of
  # it, the deposit looked twice as effective as it was, and the premium was
  # half what the policy charges.
  # Four separate tests rather than four assertions, so each figure is observed
  # to fail on its own: one of them failing first would otherwise hide the rest.
  # Upstream's (#104), adopted with #184's core swap: a variable loan has a
  # schedule but no single monthly payment -- quoting the payment it opened
  # with would present a stale figure as a current one. The figure a lender
  # quotes today is `current_minimum_payment` (#392).
  test "variable rate loans have a schedule but no single monthly payment" do
    account = Account.create! \
      family: families(:dylan_family),
      name: "Variable Mortgage",
      balance: 500000,
      currency: "USD",
      accountable: Loan.create!(subtype: "mortgage", interest_rate: 3.5, term_months: 360, rate_type: "variable")

    assert_equal account, account.loan.account, "validating a Loan before attaching its Account must not cache a missing association"
    assert account.loan.amortizable?
    assert_not_nil account.loan.amortization_schedule
    assert_nil account.loan.monthly_payment
  end

  test "a loan with no account is not amortizable rather than raising" do
    assert_not Loan.new(interest_rate: 3.5, term_months: 360, rate_type: "variable").amortizable?
    assert_not Loan.new(interest_rate: 3.5, term_months: 360, rate_type: "fixed").amortizable?
  end

  # Upstream's guard, kept: a term longer than the simulator will walk is not
  # amortizable rather than raising. The fork refuses such a term at
  # validation and in the database, so only a loan holding a rejected value in
  # memory -- a form re-rendered after a failed save -- reaches the guard, and
  # it must answer rather than raise.
  test "a term longer than the simulator will walk is not amortizable, rather than raising" do
    loan = Account.create!(
      family: families(:dylan_family), name: "Overlong", balance: 500_000, currency: "USD",
      accountable: Loan.create!(subtype: "mortgage", interest_rate: 3.5, term_months: 360, rate_type: "fixed")
    ).loan
    assert_not_nil loan.amortization_schedule, "precondition: schedulable at a valid term"

    loan.term_months = Loan::Simulator::MAX_PERIODS + 1

    assert_not loan.valid?
    assert_not loan.amortizable?
    assert_nil loan.amortization_schedule
  end

  test "the principal is the recorded one, not the first tracked balance" do
    loan = build_imported_loan_account.loan

    assert_equal 20_000, loan.original_balance.amount
  end

  test "the schedule amortises what was borrowed" do
    loan = build_imported_loan_account.loan

    repaid = loan.amortization_schedule.payments.sum(BigDecimal("0")) { |payment| payment.principal.amount }

    assert_in_delta 20_000, repaid, 1, "half a loan was being amortised"
  end

  test "repaid is measured against what was borrowed" do
    loan = build_imported_loan_account.loan

    assert_in_delta 0.5, loan.balance_paid_ratio, 0.0001, "10,000 outstanding on 20,000 borrowed is half repaid"
  end

  test "leverage is measured against what was borrowed" do
    loan = build_imported_loan_account.loan

    assert_in_delta 4.0, loan.initial_leverage_ratio, 0.001, "20,000 against a 5,000 deposit"
  end

  test "a level-term premium is charged on what was borrowed" do
    loan = build_imported_loan_account.loan

    assert_equal 6, Loan::Insurance.for(loan).premium_for(1).amount.amount, "0.36% a year on 20,000"
  end

  # The fallback, which is every loan created here: no principal is recorded
  # separately from the opening valuation, and the two must not disagree.
  test "a loan with no recorded principal still reads its first valuation" do
    loan = build_loan_account(balance: 80_000, down_payment: 20_000).loan

    assert_nil loan.initial_balance
    assert_equal 80_000, loan.original_balance.amount
  end

  # An import can write either, and neither is an amount borrowed, so both fall
  # back rather than producing a zero or a negative principal.
  test "a zero or negative recorded principal falls back to the first valuation" do
    account = build_loan_account(balance: 80_000, down_payment: 20_000)

    account.loan.update!(initial_balance: 0)
    assert_equal 80_000, account.loan.reload.original_balance.amount

    account.loan.update!(initial_balance: -5_000)
    assert_equal 80_000, account.loan.reload.original_balance.amount
  end

  # Fork-side, #184 phase 2. `original_balance` is memoised so one
  # check-then-rebuild cycle reads the account once. Now that it reads a Loan
  # column as well, assigning that column has to drop the memo, or a loan
  # edited in memory keeps amortising the principal it was loaded with.
  test "assigning a principal drops the memoised original balance" do
    loan = build_imported_loan_account.loan
    assert_equal 20_000, loan.original_balance.amount, "precondition: memoised"

    loan.initial_balance = 25_000

    assert_equal 25_000, loan.original_balance.amount
    assert_equal 25_000, loan.amortization_schedule.principal,
      "and the schedule is rebuilt from it"
  end

  # The same memo, reached through `reload`: update_columns writes without
  # the attribute writer, which is what any other process's write looks like
  # to an instance held across it.
  test "reloading drops the memoised original balance" do
    loan = build_imported_loan_account.loan
    assert_equal 20_000, loan.original_balance.amount, "precondition: memoised"

    loan.update_columns(initial_balance: 30_000)

    assert_equal 30_000, loan.reload.original_balance.amount
  end

  # The signature restages persisted schedules on read (#39). A loan whose
  # recorded principal agrees with its opening valuation -- every loan the
  # account form creates -- must hash exactly as it did when the principal
  # was read from the valuation, or deploying this restages the estate to
  # produce identical figures. Measured as a delta: the same loan with the
  # principal recorded and with it cleared.
  test "a recorded principal equal to the opening valuation leaves the schedule signature untouched" do
    loan = build_imported_loan_account.loan
    loan.update_columns(initial_balance: 10_000)
    recorded = Loan.find(loan.id).amortization_schedule_signature

    loan.update_columns(initial_balance: nil)
    unrecorded = Loan.find(loan.id).amortization_schedule_signature

    assert_equal unrecorded, recorded
  end

  # The other side of the boundary: a principal that disagrees with the
  # valuation IS a different schedule, so persisted rows built from the
  # valuation must read as stale.
  test "a recorded principal that differs from the opening valuation changes the schedule signature" do
    loan = build_imported_loan_account.loan
    differing = Loan.find(loan.id).amortization_schedule_signature

    loan.update_columns(initial_balance: nil)

    assert_not_equal differing, Loan.find(loan.id).amortization_schedule_signature
  end

  # The principal is now a schedule input, so saving a new one queues the
  # rebuild the other schedule columns queue. The read path would notice the
  # signature change anyway; this keeps the write path from relying on it.
  test "saving a new principal queues a schedule rebuild" do
    loan = build_imported_loan_account.loan
    clear_enqueued_jobs

    assert_enqueued_with(job: LoanAmortizationRebuildJob, args: [ loan.id ]) do
      loan.update!(initial_balance: 25_000)
    end
  end

  test "rejects invalid subtype" do
    loan = Loan.new(subtype: "invalid")

    assert_not loan.valid?
    assert_includes loan.errors[:subtype], "is not included in the list"
  end

  # --- #14: structured rate-change rows assembled into the jsonb column ------
  #
  # The column is not mass-assignable on purpose (R13), so the form submits
  # rows and the model assembles. These cover what the assembly has to get
  # right; the values themselves are judged by the existing
  # variable_rate_schedule validation.

  test "rate_changes rows are assembled into the variable rate schedule" do
    loan = Loan.new(subtype: "mortgage", rate_type: "variable", interest_rate: 5, term_months: 12)
    loan.rate_changes = [
      { effective_date: "2024-03-01", rate: "4.5" },
      { effective_date: "2024-06-01", rate: "6.0" }
    ]

    assert loan.valid?
    # Values arrive as strings from the form and are normalised to numbers by
    # quantize_variable_rate_schedule, which runs after assembly by design.
    assert_equal({ "2024-03-01" => 4.5, "2024-06-01" => 6.0 }, loan.variable_rate_schedule)
  end

  test "a repeated effective date replaces rather than duplicating" do
    loan = Loan.new(subtype: "mortgage", rate_type: "variable", interest_rate: 5, term_months: 12)
    loan.rate_changes = [
      { effective_date: "2024-03-01", rate: "4.5" },
      { effective_date: "2024-03-01", rate: "7.25" }
    ]

    assert loan.valid?
    # One date carries one rate, matching add_variable_rate_change's merge
    # semantics -- the later row wins rather than the schedule holding two
    # entries the calculation would have to choose between.
    assert_equal({ "2024-03-01" => 7.25 }, loan.variable_rate_schedule)
  end

  test "a row marked for removal is dropped, and a wholly blank row is ignored" do
    loan = Loan.new(subtype: "mortgage", rate_type: "variable", interest_rate: 5, term_months: 12)
    loan.rate_changes = [
      { effective_date: "2024-03-01", rate: "4.5" },
      { effective_date: "2024-06-01", rate: "6.0", _destroy: "1" },
      { effective_date: "", rate: "" }
    ]

    assert loan.valid?
    assert_equal({ "2024-03-01" => 4.5 }, loan.variable_rate_schedule)
  end

  # A typo must come back as a correctable field error. Parsing during assembly
  # would raise instead, turning a wrong date into a 500.
  test "an invalid row is rejected by validation rather than raising" do
    loan = Loan.new(subtype: "mortgage", rate_type: "variable", interest_rate: 5, term_months: 12)
    loan.rate_changes = [ { effective_date: "not-a-date", rate: "4.5" } ]

    assert_nothing_raised { loan.valid? }
    assert_not loan.valid?
    assert_includes loan.errors[:variable_rate_schedule].to_sentence, "invalid effective date"
  end

  test "a rate outside the supported range is rejected" do
    loan = Loan.new(subtype: "mortgage", rate_type: "variable", interest_rate: 5, term_months: 12)
    loan.rate_changes = [ { effective_date: "2024-03-01", rate: "150" } ]

    assert_not loan.valid?
    assert_includes loan.errors[:variable_rate_schedule].to_sentence, "0-100"
  end

  # Not supplying the rows at all must leave an existing schedule alone --
  # otherwise saving any other attribute would silently wipe the rate history.
  test "omitting rate_changes leaves an existing schedule untouched" do
    loan = Loan.create!(subtype: "mortgage", rate_type: "variable", interest_rate: 5, term_months: 12,
                        variable_rate_schedule: { "2024-03-01" => "4.5" })

    loan.update!(term_months: 24)

    assert_equal({ "2024-03-01" => 4.5 }, loan.reload.variable_rate_schedule)
  end

  test "rejects an unsupported day-count convention" do
    loan = Loan.new(day_count_convention: "actual_366")

    assert_not loan.valid?
    assert_includes loan.errors[:day_count_convention], "is not included in the list"
  end

  # #184's 2026-09-30 decision: new loans start on upstream's basis.
  test "a new loan defaults to the 30/360 day-count convention" do
    assert_equal "thirty_360", Loan.new.day_count_convention
    assert_equal "thirty_360", Loan::DEFAULT_DAY_COUNT_CONVENTION
  end

  # The signature gates a rebuild that runs on READ paths, so a loan on the
  # legacy actual/365 basis -- every loan created before #188 -- must hash
  # exactly as it did before the attribute existed. Otherwise deploying this
  # rebuilds every persisted schedule on first view to produce identical
  # figures.
  test "the legacy day-count convention leaves the schedule signature untouched" do
    loan_account = Account.create! \
      family: families(:dylan_family),
      name: "Mortgage Loan",
      balance: 500000,
      currency: "USD",
      accountable: Loan.create!(
        subtype: "mortgage",
        interest_rate: 3.5,
        term_months: 360,
        rate_type: "fixed",
        day_count_convention: "actual_365"
      )

    loan = loan_account.loan
    legacy_signature = Digest::SHA256.hexdigest([
      LoanAmortization::ALGORITHM_VERSION,
      loan.account.id,
      loan.original_balance.amount.to_s,
      loan.account.currency,
      loan.account_opening_anchor_date.to_s,
      loan.interest_rate.to_s,
      loan.term_months.to_s,
      loan.rate_type.to_s,
      loan.start_date&.iso8601,
      loan.variable_rates.map { |date, rate| [ date.to_s, loan.send(:normalized_rate, rate).to_s ] }
    ].to_json)

    assert_equal "actual_365", loan.day_count_convention
    assert_equal legacy_signature, loan.send(:amortization_schedule_signature),
      "a loan on the legacy basis must keep the signature it had before the attribute existed"

    loan.update!(day_count_convention: "thirty_360")
    assert_not_equal legacy_signature, loan.send(:amortization_schedule_signature),
      "the new default is not the legacy basis, so it must reach the signature"
    loan.update!(day_count_convention: "actual_365")

    loan.update!(day_count_convention: "actual_actual")
    assert_not_equal legacy_signature, loan.send(:amortization_schedule_signature)

    loan.update!(day_count_convention: "actual_365")
    assert_equal legacy_signature, loan.send(:amortization_schedule_signature),
      "returning to actual/365 must return the loan to its original schedule identity"
  end

  test "changing the day-count convention rebuilds the amortization schedule" do
    loan_account = Account.create! \
      family: families(:dylan_family),
      name: "Mortgage Loan",
      balance: 500000,
      currency: "USD",
      accountable: Loan.create!(
        subtype: "mortgage",
        interest_rate: 3.5,
        term_months: 360,
        rate_type: "fixed"
      )

    loan = loan_account.loan
    before = loan.send(:amortization_schedule_signature)

    assert_enqueued_with(job: LoanAmortizationRebuildJob, args: [ loan.id ]) do
      loan.update!(day_count_convention: "actual_actual")
    end

    assert_not_equal before, loan.send(:amortization_schedule_signature),
      "the convention must be part of the schedule signature, or a change would serve a stale schedule"
  end

  test "rejects malformed variable rate schedule entries" do
    loan = Loan.new(variable_rate_schedule: { "not-a-date" => "not-a-rate" })

    assert_not loan.valid?
    assert_includes loan.errors[:variable_rate_schedule], "contains an invalid effective date"
    assert_includes loan.errors[:variable_rate_schedule], "contains a non-numeric rate"
  end

  test "rejects a variable rate schedule entry outside the supported range" do
    loan = Loan.new(variable_rate_schedule: { "2027-01-01" => -1, "2028-01-01" => 250 })

    assert_not loan.valid?
    assert_includes loan.errors[:variable_rate_schedule], "contains a rate outside the supported 0-100 range"
  end

  test "quantizes variable rate schedule entries to 3 decimal places" do
    loan = Loan.new(rate_type: "variable", variable_rate_schedule: { "2027-01-01" => 5.123456 })
    assert loan.valid?
    assert_equal 5.123, loan.variable_rate_schedule["2027-01-01"]
  end

  test "rejects term months outside the supported range" do
    loan = Loan.new(term_months: 0)
    assert_not loan.valid?
    assert_includes loan.errors[:term_months], "must be greater than 0"

    loan = Loan.new(term_months: Loan::MAX_TERM_MONTHS + 1)
    assert_not loan.valid?
    assert_includes loan.errors[:term_months], "must be less than or equal to #{Loan::MAX_TERM_MONTHS}"
  end

  test "rejects an interest rate outside the supported range" do
    loan = Loan.new(interest_rate: -1)
    assert_not loan.valid?
    assert_includes loan.errors[:interest_rate], "must be greater than or equal to 0"

    loan = Loan.new(interest_rate: 101)
    assert_not loan.valid?
    assert_includes loan.errors[:interest_rate], "must be less than or equal to 100"
  end

  test "calculates correct monthly payment for fixed rate loan" do
    loan_account = Account.create! \
      family: families(:dylan_family),
      name: "Mortgage Loan",
      balance: 500000,
      currency: "USD",
      accountable: Loan.create!(
        subtype: "mortgage",
        interest_rate: 3.5,
        term_months: 360,
        rate_type: "fixed"
      )

    assert_equal BigDecimal("2245.22"), loan_account.loan.monthly_payment.amount
  end

  test "amortization_schedule returns valid schedule for fixed rate loan" do
    loan_account = Account.create! \
      family: families(:dylan_family),
      name: "Mortgage Loan",
      balance: 500000,
      currency: "USD",
      accountable: Loan.create!(
        subtype: "mortgage",
        interest_rate: 3.5,
        term_months: 360,
        rate_type: "fixed"
      )

    schedule = loan_account.loan.amortization_schedule
    assert loan_account.loan.amortizable?
    assert_equal 360, schedule.payments.length
    assert schedule.payoff_date.present?
    assert schedule.total_interest.positive?
    assert schedule.periodic_payment.positive?
  end

  test "amortization_schedule is amortizable for variable rate loan with a base rate" do
    loan_account = Account.create! \
      family: families(:dylan_family),
      name: "Variable Rate Loan",
      balance: 500000,
      currency: "USD",
      accountable: Loan.create!(
        subtype: "line_of_credit",
        interest_rate: 3.5,
        term_months: 360,
        rate_type: "variable"
      )

    assert loan_account.loan.amortizable?
    assert_not_nil loan_account.loan.amortization_schedule
  end

  test "amortization_schedule not amortizable for loan without an interest rate" do
    loan_account = Account.create! \
      family: families(:dylan_family),
      name: "No Rate Loan",
      balance: 500000,
      currency: "USD",
      accountable: Loan.create!(
        subtype: "other",
        interest_rate: nil,
        term_months: 360,
        rate_type: "fixed"
      )

    assert_not loan_account.loan.amortizable?
    assert_nil loan_account.loan.amortization_schedule
  end

  test "amortizable? is false before the loan has an account" do
    loan = Loan.create!(
      subtype: "mortgage",
      interest_rate: 3.5,
      term_months: 360,
      rate_type: "fixed"
    )

    assert_nil loan.account
    assert_not loan.amortizable?
    assert_equal 0, loan.amortizations.count
  end

  test "an amortization rebuild is enqueued (not run inline) when terms change" do
    loan_account = Account.create! \
      family: families(:dylan_family),
      name: "Mortgage Loan",
      balance: 500000,
      currency: "USD",
      accountable: Loan.create!(
        subtype: "mortgage",
        interest_rate: 3.5,
        term_months: 360,
        rate_type: "fixed"
      )

    loan = loan_account.loan
    assert_equal 0, loan.amortizations.count

    assert_enqueued_with(job: LoanAmortizationRebuildJob, args: [ loan.id ]) do
      loan.update!(interest_rate: 4.0)
    end
    assert_equal 0, loan.amortizations.count, "the save itself must not synchronously build the schedule"

    perform_enqueued_jobs
    assert_equal 360, loan.amortizations.count
  end

  test "clears the persisted schedule when a loan becomes non-amortizable" do
    loan_account = Account.create! \
      family: families(:dylan_family),
      name: "Mortgage Loan",
      balance: 500000,
      currency: "USD",
      accountable: Loan.create!(
        subtype: "mortgage",
        interest_rate: 3.5,
        term_months: 360,
        rate_type: "fixed"
      )

    loan = loan_account.loan
    loan.rebuild_amortization_schedule
    assert_equal 360, loan.amortizations.count

    perform_enqueued_jobs do
      loan.update!(interest_rate: nil)
    end

    assert_equal 0, loan.amortizations.count
  end

  test "rebuilds the persisted schedule when Account-derived inputs change" do
    loan_account = Account.create! \
      family: families(:dylan_family),
      name: "Mortgage Loan",
      balance: 500000,
      currency: "USD",
      accountable: Loan.create!(
        subtype: "mortgage",
        interest_rate: 3.5,
        term_months: 360,
        rate_type: "fixed"
      )

    loan = loan_account.loan
    loan.ensure_amortization_schedule_current!
    assert_equal 360, loan.amortizations.count
    original_signature = loan.amortizations.ordered.first.schedule_signature

    loan_account.update!(balance: 450000)
    loan.ensure_amortization_schedule_current!

    assert_not_equal original_signature, loan.amortizations.ordered.first.schedule_signature
    assert_equal BigDecimal("450000"), loan.amortizations.ordered.first.beginning_balance
  end

  test "ensure_amortization_schedule_current! does not duplicate rows when called repeatedly" do
    loan_account = Account.create! \
      family: families(:dylan_family),
      name: "Mortgage Loan",
      balance: 500000,
      currency: "USD",
      accountable: Loan.create!(
        subtype: "mortgage",
        interest_rate: 3.5,
        term_months: 360,
        rate_type: "fixed"
      )

    loan = loan_account.loan
    assert_equal 0, loan.amortizations.count

    3.times { loan.ensure_amortization_schedule_current! }

    assert_equal 360, loan.amortizations.count
  end

  test "ensure_amortization_schedule_current! serializes the check-then-rebuild through a row lock" do
    loan_account = Account.create! \
      family: families(:dylan_family),
      name: "Mortgage Loan",
      balance: 500000,
      currency: "USD",
      accountable: Loan.create!(
        subtype: "mortgage",
        interest_rate: 3.5,
        term_months: 360,
        rate_type: "fixed"
      )

    loan = loan_account.loan
    loan.expects(:with_lock).once.yields
    loan.ensure_amortization_schedule_current!
  end

  test "adds variable rate changes" do
    loan_account = Account.create! \
      family: families(:dylan_family),
      name: "Variable Rate Loan",
      balance: 500000,
      currency: "USD",
      accountable: Loan.create!(
        subtype: "line_of_credit",
        interest_rate: 3.5,
        term_months: 360,
        rate_type: "variable"
      )

    loan = loan_account.loan
    loan.add_variable_rate_change(Date.new(2027, 1, 1), 4.0)
    loan.add_variable_rate_change(Date.new(2028, 1, 1), 4.5)

    assert_equal 2, loan.variable_rates.length
    assert_equal 4.0, loan.variable_rates[0][1]
    assert_equal 4.5, loan.variable_rates[1][1]
    # Inside travel_to: next_rate_change_date compares against Date.current, so
    # asserting a hard-coded 2027 date against the real clock is a test that
    # starts failing on 2027-01-01 for no reason connected to the code.
    travel_to Date.new(2026, 1, 1) do
      assert_equal Date.new(2027, 1, 1), loan.next_rate_change_date
    end

    travel_to Date.new(2027, 1, 2) do
      assert_equal Date.new(2028, 1, 1), loan.next_rate_change_date
    end

    travel_to Date.new(2028, 1, 2) do
      assert_nil loan.next_rate_change_date
    end
  end

  test "gets current variable rate based on date" do
    loan_account = Account.create! \
      family: families(:dylan_family),
      name: "Variable Rate Loan",
      balance: 500000,
      currency: "USD",
      accountable: Loan.create!(
        subtype: "line_of_credit",
        interest_rate: 3.5,
        term_months: 360,
        rate_type: "variable",
        variable_rate_schedule: {
          "2024-01-01" => 3.5,
          "2026-01-01" => 4.0,
          "2027-01-01" => 4.5
        }
      )

    loan = loan_account.loan
    assert_equal 3.5, loan.current_variable_rate(Date.new(2024, 6, 1))
    assert_equal 4.0, loan.current_variable_rate(Date.new(2026, 6, 1))
    assert_equal 4.5, loan.current_variable_rate(Date.new(2027, 6, 1))
  end

  test "payoff_projection builds the projection for the date it is asked about" do
    loan_account = Account.create! \
      family: families(:dylan_family),
      name: "Mortgage Loan",
      balance: 500000,
      currency: "USD",
      accountable: Loan.create!(
        subtype: "mortgage",
        interest_rate: 3.5,
        term_months: 360,
        rate_type: "fixed",
        start_date: Date.current
      )

    loan = loan_account.loan
    assert_instance_of Loan::PayoffProjection, loan.payoff_projection
    assert_equal Date.current, loan.payoff_projection.as_of
    # Not memoised (upstream's #payoff_projection): `as_of` makes each call a
    # different question, and the balance it reads moves without a callback.
    assert_equal Date.current + 1.month, loan.payoff_projection(as_of: Date.current + 1.month).as_of
  end

  test "payoff_projection_with_extra returns a fresh projection boosted by the given amount" do
    loan = build_chart_loan(balance: 500000)

    with_extra = loan.payoff_projection_with_extra(amount: "100")

    assert_not_same loan.payoff_projection, with_extra
    assert_equal loan.payoff_projection.monthly_payment + Money.new(100, "USD"), with_extra.monthly_payment
  end

  # cubic, #78: a rate-type-only edit must not take the offset links with it.
  #
  # Asserted on a FRESHLY LOADED record on purpose. The first version of this
  # test reused the instance that had just set offset_account_ids, so the
  # virtual attribute was still populated and the deletion never happened --
  # a green test over a live defect. A real request always loads the loan
  # fresh, which is the case that mattered.
  test "moving between two variable rate types without submitting offsets keeps them" do
    family = families(:dylan_family)
    loan = family.accounts.create!(
      name: "Offset Retention Loan", balance: 250_000, currency: "USD",
      accountable: Loan.new(rate_type: "variable", interest_rate: 5, term_months: 240)
    ).loan
    offset = family.accounts.create!(
      name: "Retention Offset", balance: 10_000, currency: "USD", accountable: Depository.new
    )
    loan.update!(offset_account_ids: [ offset.id ])
    assert_equal [ offset.id ], Loan.find(loan.id).offset_accounts.pluck(:id)

    Loan.find(loan.id).update!(rate_type: "adjustable")

    assert_equal [ offset.id ], Loan.find(loan.id).offset_accounts.pluck(:id),
      "a rate-type-only edit submits no offset ids; that must not be read as 'remove them all'"
  end

  test "moving to a fixed rate without submitting offsets still removes them" do
    family = families(:dylan_family)
    loan = family.accounts.create!(
      name: "Offset Removal Loan", balance: 250_000, currency: "USD",
      accountable: Loan.new(rate_type: "variable", interest_rate: 5, term_months: 240)
    ).loan
    offset = family.accounts.create!(
      name: "Removal Offset", balance: 10_000, currency: "USD", accountable: Depository.new
    )
    loan.update!(offset_account_ids: [ offset.id ])

    Loan.find(loan.id).update!(rate_type: "fixed")

    assert_empty Loan.find(loan.id).offset_accounts,
      "a fixed-rate loan has no offset, so the links must go"
  end

  # CodeRabbit, #86: `validate_offset_accounts` was registered with
  # `before_save`, where `errors.add` does not stop the write -- only
  # `throw :abort` does. An unknown id therefore saved cleanly, and
  # `sync_offset_accounts` then persisted only the accounts it could load, so
  # the user was told the edit succeeded while the link silently did not exist.
  test "an unknown offset account id fails the save instead of being dropped" do
    family = families(:dylan_family)
    loan = family.accounts.create!(
      name: "Unknown Offset Loan", balance: 250_000, currency: "USD",
      accountable: Loan.new(rate_type: "variable", interest_rate: 5, term_months: 240)
    ).loan

    assert_no_difference "LoanOffsetAccount.count" do
      refute loan.update(offset_account_ids: [ SecureRandom.uuid ]),
        "an unknown offset account id must make the save fail, not succeed silently"
    end

    assert_includes loan.errors[:offset_account_ids], "contains an unknown account"
    assert_empty Loan.find(loan.id).offset_accounts
  end

  # An account that EXISTS but is ineligible already failed the save before this
  # change -- measured, not assumed: under `before_save` this same case returned
  # false and created no link, because the after-save sync cannot persist a link
  # LoanOffsetAccount refuses. Only a genuinely unknown id slipped through, which
  # is why the test above is the one that goes red without the fix. Kept as a
  # characterisation test so moving the callback does not quietly regress it.
  test "an ineligible offset account fails the save instead of being dropped" do
    family = families(:dylan_family)
    loan = family.accounts.create!(
      name: "Ineligible Offset Loan", balance: 250_000, currency: "USD",
      accountable: Loan.new(rate_type: "variable", interest_rate: 5, term_months: 240)
    ).loan
    wrong_currency = family.accounts.create!(
      name: "Ineligible Offset", balance: 10_000, currency: "EUR", accountable: Depository.new
    )

    assert_no_difference "LoanOffsetAccount.count" do
      refute loan.update(offset_account_ids: [ wrong_currency.id ]),
        "an offset account in another currency must make the save fail"
    end

    assert_predicate loan.errors[:offset_account_ids], :any?
    assert_empty Loan.find(loan.id).offset_accounts
  end

  # CodeRabbit, #87: the first draft of this fix broke every ordinary edit of a
  # variable loan that already had an offset. `validate_offset_accounts` built a
  # fresh `LoanOffsetAccount` for each submitted account, and a NEW record
  # cannot exclude itself from the account_id-unique-within-loan_id rule, so the
  # link being KEPT collided with its own existing row. Harmless while this ran
  # on `before_save` and the error was ignored; fatal once it became a real
  # validation, because the form pre-populates the existing ids.
  test "re-submitting an offset account the loan already has does not fail the save" do
    family = families(:dylan_family)
    loan = family.accounts.create!(
      name: "Retained Offset Loan", balance: 250_000, currency: "USD",
      accountable: Loan.new(rate_type: "variable", interest_rate: 5, term_months: 240)
    ).loan
    offset = family.accounts.create!(
      name: "Retained Offset", balance: 10_000, currency: "USD", accountable: Depository.new
    )
    loan.update!(offset_account_ids: [ offset.id ])

    fresh = Loan.find(loan.id)
    assert fresh.update(offset_account_ids: [ offset.id ], interest_rate: 6),
      "keeping an existing offset must not collide with its own join row"

    reloaded = Loan.find(loan.id)
    assert_equal [ offset.id ], reloaded.offset_accounts.pluck(:id)
    assert_equal 6, reloaded.interest_rate.to_i,
      "the unrelated edit in the same save must not be rolled back"
  end

  # Guards the other direction: making this a validation must not stop a
  # legitimate offset edit from going through.
  test "a valid offset account still saves and links" do
    family = families(:dylan_family)
    loan = family.accounts.create!(
      name: "Valid Offset Loan", balance: 250_000, currency: "USD",
      accountable: Loan.new(rate_type: "variable", interest_rate: 5, term_months: 240)
    ).loan
    offset = family.accounts.create!(
      name: "Valid Offset", balance: 10_000, currency: "USD", accountable: Depository.new
    )

    assert loan.update(offset_account_ids: [ offset.id ])
    assert_equal [ offset.id ], Loan.find(loan.id).offset_accounts.pluck(:id)
  end

  # #223. The dated-rate rules, shared by every provider that reports a
  # variable rate. The loan only answers what should be written; the provider
  # writes it, so locks and provenance stay with the provider's writer.
  test "variable_rate_update_for sets the base rate on a first sighting" do
    loan = Loan.new(rate_type: "variable", interest_rate: nil)

    assert_equal({ interest_rate: BigDecimal("5.2") },
                 loan.variable_rate_update_for(5.2, as_of: Date.new(2026, 1, 15)))
  end

  test "variable_rate_update_for dates a moved rate to as_of, not today" do
    loan = Loan.new(rate_type: "variable", interest_rate: 4.5)

    update = loan.variable_rate_update_for(5.2, as_of: Date.new(2026, 1, 15))

    assert_equal({ "2026-01-15" => "5.2" }, update[:variable_rate_schedule])
    assert_not update.key?(:interest_rate), "the base rate must not move"
  end

  test "variable_rate_update_for keeps the rows already on the schedule" do
    loan = Loan.new(rate_type: "variable", interest_rate: 4.5,
                    variable_rate_schedule: { "2025-06-01" => 4.8 })

    update = loan.variable_rate_update_for(5.2, as_of: Date.new(2026, 1, 15))

    assert_equal %w[2025-06-01 2026-01-15], update[:variable_rate_schedule].keys.sort
  end

  test "variable_rate_update_for records nothing when the rate in force is unchanged" do
    loan = Loan.new(rate_type: "variable", interest_rate: 4.5,
                    variable_rate_schedule: { "2025-06-01" => 5.125 })

    # A four-decimal reading of the three-decimal stored rate is not a change.
    assert_nil loan.variable_rate_update_for(BigDecimal("5.1249"), as_of: Date.new(2026, 1, 15))
  end

  test "variable_rate_update_for records nothing when today's row already holds the rate" do
    loan = Loan.new(rate_type: "variable", interest_rate: 4.5,
                    variable_rate_schedule: { "2026-01-15" => 5.2 })

    assert_nil loan.variable_rate_update_for(5.2, as_of: Date.new(2026, 1, 15))
  end

  # cubic, #400 (sibling of the rule's clash check): a same-day row stored under
  # another ISO spelling is replaced, not joined by a second row for that day,
  # which would leave the rate in force to hash order.
  test "variable_rate_update_for replaces a same-day row under another ISO spelling" do
    loan = Loan.new(rate_type: "variable", interest_rate: 4.5,
                    variable_rate_schedule: { "2025-06-01" => 4.8, "20260115" => 5.0 })

    update = loan.variable_rate_update_for(5.2, as_of: Date.new(2026, 1, 15))

    assert_equal({ "2025-06-01" => 4.8, "2026-01-15" => "5.2" }, update[:variable_rate_schedule])
  end

  test "variable_rate_update_for leaves a fixed loan to its caller" do
    loan = Loan.new(rate_type: "fixed", interest_rate: 4.5)

    assert_nil loan.variable_rate_update_for(5.2, as_of: Date.new(2026, 1, 15))
  end

  private
    # A loan imported part way through its life: the principal it was written
    # for is recorded, and the only valuation the account carries is the
    # balance on the day it was linked.
    def build_imported_loan_account
      account = Account.create!(
        family: families(:dylan_family),
        name: "Imported #{SecureRandom.hex(3)}",
        balance: 10_000,
        currency: "USD",
        accountable: Loan.create!(
          subtype: "mortgage", interest_rate: 5, term_months: 120, rate_type: "fixed",
          initial_balance: 20_000, down_payment: 5_000,
          insurance_rate: 0.36, insurance_rate_type: "level_term",
          start_date: 5.years.ago.to_date
        )
      )
      account.entries.create!(
        name: "Starting balance", amount: 10_000, currency: "USD",
        date: 5.years.ago.to_date, entryable: Valuation.new(kind: "opening_anchor")
      )
      account
    end

    def build_loan_account(balance:, down_payment:)
      Account.create!(
        family: families(:dylan_family),
        name: "Leveraged #{SecureRandom.hex(3)}",
        balance: balance,
        currency: "USD",
        accountable: Loan.create!(
          subtype: "mortgage", interest_rate: 5, term_months: 120,
          rate_type: "fixed", down_payment: down_payment
        )
      )
    end

    def build_chart_loan(balance:, interest_rate: 3.5, term_months: 360, start_date: Date.current, rate_type: "fixed")
      account = Account.create! \
        family: families(:dylan_family),
        name: "Chart Loan #{SecureRandom.hex(4)}",
        balance: balance,
        currency: "USD",
        accountable: Loan.create!(
          subtype: "mortgage",
          interest_rate: interest_rate,
          term_months: term_months,
          rate_type: rate_type,
          start_date: start_date
        )

      account.entries.create!(
        name: "Starting balance",
        amount: balance,
        currency: "USD",
        date: start_date,
        entryable: Valuation.new(kind: "opening_anchor")
      )

      # Amortization rebuilds happen asynchronously (after_save enqueues
      # LoanAmortizationRebuildJob rather than rebuilding inline) -- build the
      # persisted schedule synchronously here so tests read current rows
      # without needing perform_enqueued_jobs.
      account.loan.tap(&:rebuild_amortization_schedule)
    end
end
