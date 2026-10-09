require "test_helper"

# #142 phase 2: a rule that reads a rate change out of a loan transaction's
# description and records it on the loan's schedule, through the same guarded
# path the Redbark and Plaid rate detection use.
#
# The descriptions are representative wordings written for these tests, not
# texts collected from real bank feeds (see Loan::RateChangeText).
class Rule::ActionExecutor::RecordLoanRateChangeTest < ActiveSupport::TestCase
  include EntriesTestHelper
  include ActiveJob::TestHelper

  setup do
    @family = families(:empty)
    @loan_account = @family.accounts.create!(
      name: "Mortgage",
      balance: 400_000,
      currency: "AUD",
      accountable: Loan.new(rate_type: "variable", interest_rate: 6.49, term_months: 360)
    )
    @loan = @loan_account.accountable
    @date = Date.new(2026, 9, 14)

    @rule = @family.rules.create!(
      name: "Loan rate changes",
      resource_type: "transaction",
      effective_date: Date.new(2020, 1, 1),
      actions: [ Rule::Action.new(action_type: "record_loan_rate_change") ]
    )
  end

  # --- Positive -----------------------------------------------------------------

  test "a new-rate description on a variable loan records the rate on the transaction's date" do
    loan_transaction "INTEREST RATE CHANGE - NEW RATE 6.24% P.A."

    # The clock is moved well away from the transaction's date: only the
    # entry's own date may key the row.
    travel_to Date.new(2026, 12, 25) do
      @rule.apply
    end

    assert_equal({ "2026-09-14" => BigDecimal("6.24") }, rates)
    assert_equal BigDecimal("6.49"), BigDecimal(@loan.reload.interest_rate.to_s),
                 "the base rate was overwritten instead of a dated change being recorded"
  end

  test "a rate stated only in the notes is recorded" do
    loan_transaction "LOAN ACCOUNT NOTICE", notes: "Your variable rate has changed from 6.49% to 6.24%"

    @rule.apply

    assert_equal({ "2026-09-14" => BigDecimal("6.24") }, rates)
  end

  # 6.49 is the rate already in force, so reading the FROM rate would record
  # nothing at all: the row's presence is what proves the TO rate was taken.
  test "a from-to description records the rate it changed to" do
    loan_transaction "Your variable rate has changed from 6.49% to 6.24%"

    @rule.apply

    assert_equal({ "2026-09-14" => BigDecimal("6.24") }, rates)
  end

  test "the name is read before the notes" do
    loan_transaction "NEW RATE 6.24% P.A.", notes: "Rate change 6.10%"

    @rule.apply

    assert_equal({ "2026-09-14" => BigDecimal("6.24") }, rates)
  end

  test "a recorded change carries rule provenance" do
    loan_transaction "NEW RATE 6.24% P.A."

    assert_difference -> { DataEnrichment.where(enrichable: @loan, attribute_name: "variable_rate_schedule", source: "rule").count }, 1 do
      @rule.apply
    end
  end

  test "apply counts the transactions whose rate was recorded" do
    loan_transaction "NEW RATE 6.24% P.A."
    loan_transaction "LOAN REPAYMENT", date: @date - 1

    assert_equal 1, @rule.apply
  end

  # A loan with no base rate takes the first reading as its base rate, as the
  # provider path does (Loan#variable_rate_update_for): a first reading is not
  # evidence that anything changed, so it gets no dated row.
  test "a loan with no base rate takes the reading as its base rate" do
    @loan.update!(interest_rate: nil)
    loan_transaction "NEW RATE 6.24% P.A."

    @rule.apply

    assert_equal BigDecimal("6.24"), @loan.reload.interest_rate
    assert_empty schedule
  end

  # --- Negative: the loan --------------------------------------------------------

  test "a fixed loan records nothing and the disagreement is logged" do
    @loan.update!(rate_type: "fixed")
    loan_transaction "NEW RATE 6.24% P.A."

    assert_difference -> { DebugLogEntry.where(category: "loan_rate").count }, 1 do
      assert_equal 0, @rule.apply
    end

    @loan.reload
    assert_empty schedule
    assert_equal BigDecimal("6.49"), BigDecimal(@loan.interest_rate.to_s), "a fixed loan's rate was overwritten"
    assert_equal "fixed", @loan.rate_type
  end

  # Phase 1 adopts `variable` for a blank rate type only on the bank's own
  # structured word for it. A description parsed by a rule is not that, so a
  # blank rate type is treated as not variable.
  test "a loan with no rate type records nothing and is logged" do
    @loan.update_columns(rate_type: nil)
    loan_transaction "NEW RATE 6.24% P.A."

    assert_difference -> { DebugLogEntry.where(category: "loan_rate").count }, 1 do
      @rule.apply
    end

    @loan.reload
    assert_empty schedule
    assert_nil @loan.rate_type, "the rule classified the loan from a free-text description"
  end

  test "a locked schedule is not added to" do
    @loan.lock_attr!(:variable_rate_schedule)
    loan_transaction "NEW RATE 6.24% P.A."

    assert_equal 0, @rule.apply, "a skipped write was counted as a modification"

    assert_empty schedule, "a schedule the user edited was written by a rule"
  end

  # "Apply rule" in the UI runs with ignore_attribute_locks: true. That flag is
  # about the TRANSACTION attributes a rule owns; it does not hand the rule the
  # user's hand-edited loan schedule.
  test "a locked schedule is not added to even when the rule ignores locks" do
    @loan.lock_attr!(:variable_rate_schedule)
    loan_transaction "NEW RATE 6.24% P.A."

    assert_equal 0, @rule.apply(ignore_attribute_locks: true)

    assert_empty schedule, "a manual re-apply overrode the user's schedule lock"
  end

  test "a rate equal to the one in force records nothing and queues no rebuild" do
    loan_transaction "NEW RATE 6.49% P.A."

    assert_no_enqueued_jobs only: LoanAmortizationRebuildJob do
      assert_equal 0, @rule.apply
    end

    assert_empty schedule
  end

  # The rate in force is read ON THE TRANSACTION'S DATE, from the schedule, not
  # from the base rate and not on today's date.
  test "a rate equal to an earlier scheduled change records nothing" do
    @loan.update!(variable_rate_schedule: { "2026-06-01" => "6.24" })
    loan_transaction "NEW RATE 6.24% P.A."

    @rule.apply

    assert_equal({ "2026-06-01" => BigDecimal("6.24") }, rates)
  end

  test "a change scheduled after the transaction does not count as in force on its date" do
    @loan.update!(variable_rate_schedule: { "2026-12-01" => "6.24" })
    loan_transaction "NEW RATE 6.24% P.A."

    travel_to Date.new(2027, 1, 15) do
      @rule.apply
    end

    assert_equal({ "2026-09-14" => BigDecimal("6.24"), "2026-12-01" => BigDecimal("6.24") }, rates)
  end

  test "a row already on the transaction's date is never overwritten, and the clash is logged" do
    @loan.update!(variable_rate_schedule: { "2026-09-14" => "6.30" })
    loan_transaction "NEW RATE 6.24% P.A."

    assert_difference -> { DebugLogEntry.where(category: "loan_rate").count }, 1 do
      @rule.apply
    end

    assert_equal({ "2026-09-14" => BigDecimal("6.3") }, rates)
  end

  # cubic, #400: ISO-8601 spells a day more than one way. A row stored under the
  # basic spelling is still on the transaction's date, and a different rate
  # there is a clash, not a second row for the same day.
  test "a row on the transaction's date under another ISO spelling is a clash too" do
    @loan.update_columns(variable_rate_schedule: { "20260914" => "6.30" })
    loan_transaction "NEW RATE 6.24% P.A."

    assert_difference -> { DebugLogEntry.where(category: "loan_rate").count }, 1 do
      @rule.apply
    end

    assert_equal({ "20260914" => BigDecimal("6.3") }, rates)
  end

  test "running the rule twice records one row and queues one rebuild" do
    loan_transaction "NEW RATE 6.24% P.A."

    assert_enqueued_jobs 1, only: LoanAmortizationRebuildJob do
      @rule.apply
    end

    assert_no_enqueued_jobs only: LoanAmortizationRebuildJob do
      assert_equal 0, @rule.apply
    end

    assert_equal({ "2026-09-14" => BigDecimal("6.24") }, rates)
  end

  # The same notice repeated a few months later is not a second change. Created
  # newest first so that only date order, not insertion order, gets it right.
  test "transactions are read in date order" do
    loan_transaction "NEW RATE 6.24% P.A.", date: Date.new(2026, 11, 3)
    loan_transaction "NEW RATE 6.24% P.A.", date: @date

    @rule.apply

    assert_equal({ "2026-09-14" => BigDecimal("6.24") }, rates)
  end

  # A loan the model will not save -- here an unknown subtype written before the
  # validation existed -- refuses the write. The run must carry on rather than
  # raise, and say why nothing was recorded.
  test "a write the loan refuses records nothing and is logged" do
    @loan.update_columns(subtype: "not-a-subtype")
    loan_transaction "NEW RATE 6.24% P.A."

    assert_difference -> { DebugLogEntry.where(category: "loan_rate").count }, 1 do
      assert_equal 0, @rule.apply
    end

    assert_empty schedule
    entry = DebugLogEntry.where(category: "loan_rate").last
    assert_equal "refused", entry.metadata["problem"]
  end

  # --- Negative: the text ---------------------------------------------------------

  test "two different percentages record nothing and are logged" do
    loan_transaction "Rate 6.25% comparison rate 6.40%"

    assert_difference -> { DebugLogEntry.where(category: "loan_rate").count }, 1 do
      @rule.apply
    end

    assert_empty schedule
    entry = DebugLogEntry.where(category: "loan_rate").last
    assert_equal "ambiguous", entry.metadata["problem"]
    assert_equal @family, entry.family
    assert_equal @loan_account, entry.account
  end

  test "a rate the loan cannot hold records nothing and is logged" do
    loan_transaction "NEW RATE 150% P.A."

    assert_difference -> { DebugLogEntry.where(category: "loan_rate").count }, 1 do
      @rule.apply
    end

    assert_empty schedule
    assert_equal BigDecimal("6.49"), BigDecimal(@loan.reload.interest_rate.to_s)
  end

  test "a description with no percentage records nothing and logs nothing" do
    loan_transaction "LOAN REPAYMENT"

    assert_no_difference -> { DebugLogEntry.count } do
      assert_equal 0, @rule.apply
    end

    assert_empty schedule
  end

  # --- Negative: not a loan ---------------------------------------------------------

  # A rule's conditions can legitimately match other accounts; those are not
  # this action's business and are skipped without a word.
  test "a transaction on an account that is not a loan is skipped silently" do
    depository = @family.accounts.create!(name: "Everyday", balance: 1000, currency: "AUD", accountable: Depository.new)
    create_transaction(account: depository, name: "NEW RATE 6.24% P.A.", date: @date, amount: 0, currency: "AUD")

    assert_no_difference -> { DebugLogEntry.count } do
      assert_equal 0, @rule.apply
    end

    assert_empty schedule
  end

  # --- Registration -------------------------------------------------------------------

  test "is offered as a transaction rule action that takes no value" do
    executor = @rule.registry.action_executors.find { |e| e.key == "record_loan_rate_change" }

    assert_not_nil executor, "the action is not offered in the rule editor"
    assert_equal "function", executor.type
    assert_equal I18n.t("rule.actions.record_loan_rate_change.label"), executor.label
  end

  private
    def loan_transaction(name, date: @date, notes: nil)
      create_transaction(account: @loan_account, name: name, notes: notes, date: date, amount: 0, currency: "AUD")
    end

    def schedule
      (@loan.reload.variable_rate_schedule || {}).stringify_keys
    end

    def rates
      schedule.transform_values { |rate| BigDecimal(rate.to_s) }
    end
end
