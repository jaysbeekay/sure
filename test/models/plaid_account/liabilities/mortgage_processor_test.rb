require "test_helper"

class PlaidAccount::Liabilities::MortgageProcessorTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @plaid_account = plaid_accounts(:one)
    @plaid_account.update!(
      plaid_type: "loan",
      plaid_subtype: "mortgage"
    )

    @plaid_account.current_account.update!(accountable: Loan.new)
  end

  test "updates loan interest rate and type from Plaid data" do
    @plaid_account.update!(raw_liabilities_payload: {
      mortgage: {
        interest_rate: {
          type: "fixed",
          percentage: 4.25
        }
      }
    })

    processor = PlaidAccount::Liabilities::MortgageProcessor.new(@plaid_account)
    processor.process

    loan = @plaid_account.current_account.loan

    assert_equal "fixed", loan.rate_type
    assert_equal 4.25, loan.interest_rate
  end

  test "does nothing when mortgage data absent" do
    @plaid_account.update!(raw_liabilities_payload: {})

    processor = PlaidAccount::Liabilities::MortgageProcessor.new(@plaid_account)
    processor.process

    loan = @plaid_account.current_account.loan

    assert_nil loan.rate_type
    assert_nil loan.interest_rate
  end

  # ------------------------------------------------------------------- #158

  # Rows 1 and 2 of the plan. A value the user corrected on the loan form is
  # locked by `Account#lock_saved_attributes!`, and `update!` overwrote it on
  # the next sync -- silently, on every sync, for ever.
  test "a locked interest rate is not overwritten by Plaid" do
    loan = loan_with(interest_rate: 4.5)
    loan.lock_attr!(:interest_rate)
    payload(type: "fixed", percentage: 5.2)

    process

    assert_equal 4.5, loan.reload.interest_rate.to_f, "Plaid overwrote a rate the user had locked"
    assert_equal "fixed", loan.rate_type, "the unlocked attribute beside it was not written"
  end

  test "a locked rate type is not overwritten by Plaid" do
    loan = loan_with(rate_type: "variable", interest_rate: 4.5)
    loan.lock_attr!(:rate_type)
    payload(type: "fixed", percentage: 4.5)

    process

    assert_equal "variable", loan.reload.rate_type, "Plaid overwrote a rate type the user had locked"
  end

  # Row 3. Provenance: a later writer has to be able to tell whose value it is.
  test "an unlocked loan is updated and the provider is recorded as the source" do
    loan = loan_with(interest_rate: 4.5, rate_type: "variable")
    payload(type: "fixed", percentage: 5.2)

    assert_difference -> { DataEnrichment.count }, 2 do
      process
    end

    loan.reload
    assert_equal 5.2, loan.interest_rate.to_f
    assert_equal "fixed", loan.rate_type
    sources = DataEnrichment.where(enrichable: loan).pluck(:source).uniq
    assert_equal [ "plaid" ], sources, "the write was not attributed to Plaid"
  end

  # Row 4. An omitted field is not a value. `update!` sent nil and blanked the
  # rate the user had typed in.
  test "a payload without a percentage leaves the stored rate alone" do
    loan = loan_with(interest_rate: 4.5)
    payload(type: "fixed")

    process

    assert_equal 4.5, loan.reload.interest_rate.to_f, "an omitted percentage blanked the stored rate"
    assert_equal "fixed", loan.rate_type, "the field the payload DID carry was not written"
  end

  # Row 5. The boundary `compact_blank` would get wrong: zero is a real rate.
  test "a rate of exactly zero is written" do
    loan = loan_with(interest_rate: 4.5)
    payload(type: "fixed", percentage: 0)

    process

    assert_equal 0.0, loan.reload.interest_rate.to_f, "an interest-free loan's zero was dropped as if absent"
  end

  # Row 10. A repeat sync of the same payload is not a change.
  #
  # BOTH halves are asserted. The first version of this test only checked that
  # the SECOND sync queued nothing, which passes just as well if a changed write
  # stops queueing rebuilds at all -- the test was named for a guarantee it did
  # not hold (cubic, #222).
  test "the same payload twice records one enrichment and queues one rebuild" do
    loan_with(interest_rate: 4.5, rate_type: "variable")
    payload(type: "fixed", percentage: 5.2)

    assert_difference -> { DataEnrichment.count }, 2 do
      assert_enqueued_jobs 1, only: LoanAmortizationRebuildJob do
        process
      end
    end

    assert_no_difference -> { DataEnrichment.count } do
      assert_no_enqueued_jobs only: LoanAmortizationRebuildJob do
        process
      end
    end
  end

  # Row 11. `enrich_attributes` calls `save`, not `save!`, so a refusal returns
  # false instead of raising. On main the raise reached
  # `PlaidAccount::Processor#process_liabilities`'s rescue and was reported;
  # without an explicit capture the failure would become silent.
  test "a rate the model refuses is logged rather than raised" do
    loan = loan_with(interest_rate: 4.5)
    payload(type: "fixed", percentage: 150)

    assert_difference -> { DebugLogEntry.count }, 1 do
      assert_nothing_raised { process }
    end

    assert_equal 4.5, loan.reload.interest_rate.to_f, "an invalid rate was stored anyway"
  end

  # A refusal must not leave its REJECTED VALUE or its ERRORS on the loan for the
  # rest of the sync (cubic, #222). Observed through a second write on the same
  # processor instance, because that is the only place the leftovers are visible:
  # `enrich_attributes` returns early without saving when the attribute is
  # locked, so it never clears the errors itself, and the stale ones get reported
  # as a refusal that did not happen.
  #
  # Asserting on the test's own `loan` object proves nothing here -- the
  # processor resolves its own instance through `plaid_account.current_account`,
  # so the test's copy is never the one that was mutated. My first attempt at
  # this test did exactly that and passed with the fix removed.
  test "a refusal leaves nothing behind for a locked write to report" do
    loan = loan_with(interest_rate: 4.5, rate_type: "variable")
    loan.lock_attr!(:rate_type)
    writer = PlaidAccount::Liabilities::MortgageProcessor.new(@plaid_account.reload)

    assert_difference -> { DebugLogEntry.count }, 1 do
      writer.send(:write_loan_terms, interest_rate: 150)
      writer.send(:write_loan_terms, rate_type: "fixed")
    end

    assert_equal 4.5, loan.reload.interest_rate.to_f
    assert_equal "variable", loan.rate_type
  end

  # And the cost of NOT restoring, which is the half `errors.clear` does not
  # cover: the rejected value stays assigned, so the record is still invalid and
  # the NEXT write fails too -- a legitimate change lost to an unrelated refusal.
  # `interest_rate` and `rate_type` arrive in separate calls here, which is what
  # makes the second one observable.
  test "a refused value does not cost the next write its change" do
    loan = loan_with(interest_rate: 4.5, rate_type: "variable")
    writer = PlaidAccount::Liabilities::MortgageProcessor.new(@plaid_account.reload)

    writer.send(:write_loan_terms, interest_rate: 150)
    writer.send(:write_loan_terms, rate_type: "fixed")

    loan.reload
    assert_equal "fixed", loan.rate_type,
                 "a valid change was refused because the loan still carried a rejected value"
    assert_equal 4.5, loan.interest_rate.to_f, "the rejected rate was stored after all"
  end

  # The provenance ledger, not the loan. A refused write must not re-attribute
  # the rejected figure to Plaid. `find_or_create_by` reuses the row an earlier
  # accepted write made, so a row count cannot see this -- only the stored
  # `value` can.
  #
  # A FIXED loan, because that is where a reported rate is still written as the
  # base rate; a variable loan's rate is a dated row since #223.
  test "a refused rate leaves the previously accepted provenance value in place" do
    loan = loan_with(interest_rate: 4.5, rate_type: "fixed")
    writer = PlaidAccount::Liabilities::MortgageProcessor.new(@plaid_account.reload)

    writer.send(:write_loan_terms, interest_rate: 5.2)
    enrichment = DataEnrichment.find_by!(enrichable: loan, attribute_name: "interest_rate", source: "plaid")
    assert_equal 5.2, enrichment.value.to_f

    writer.send(:write_loan_terms, interest_rate: 150)

    assert_equal 5.2, enrichment.reload.value.to_f, "the refused rate was recorded as Plaid's value"
    assert_equal 5.2, loan.reload.interest_rate.to_f
  end

  # #223. A variable loan's rate change is a dated row, not a new base rate:
  # overwriting the base rate re-prices every period before the change.
  test "a variable mortgage's rate change is dated, not overwritten" do
    loan = loan_with(interest_rate: 4.5, rate_type: "variable")
    payload(type: "variable", percentage: 5.2)

    process_as_of(Date.new(2026, 1, 15))

    loan.reload
    assert_equal 4.5, loan.interest_rate.to_f, "the base rate was overwritten"
    assert_equal({ "2026-01-15" => 5.2 }, loan.variable_rate_schedule)
  end

  test "the dated row is keyed to the sync's date, not the clock" do
    loan = loan_with(interest_rate: 4.5, rate_type: "variable")
    payload(type: "variable", percentage: 5.2)

    travel_to Date.new(2026, 3, 1) do
      process_as_of(Date.new(2026, 1, 15))
    end

    assert_equal [ "2026-01-15" ], loan.reload.variable_rate_schedule.keys
  end

  test "the same variable rate on the next sync adds no second row" do
    loan = loan_with(interest_rate: 4.5, rate_type: "variable")
    payload(type: "variable", percentage: 5.2)
    process_as_of(Date.new(2026, 1, 15))

    process_as_of(Date.new(2026, 1, 16))

    assert_equal({ "2026-01-15" => 5.2 }, loan.reload.variable_rate_schedule)
  end

  test "a payload that turns a fixed loan variable dates the rate change" do
    loan = loan_with(interest_rate: 4.5, rate_type: "fixed")
    payload(type: "variable", percentage: 5.2)

    process_as_of(Date.new(2026, 1, 15))

    loan.reload
    assert_equal "variable", loan.rate_type
    assert_equal 4.5, loan.interest_rate.to_f
    assert_equal({ "2026-01-15" => 5.2 }, loan.variable_rate_schedule)
  end

  test "a fixed mortgage's rate is still written as the base rate" do
    loan = loan_with(interest_rate: 4.5, rate_type: "fixed")
    payload(type: "fixed", percentage: 5.2)

    process_as_of(Date.new(2026, 1, 15))

    loan.reload
    assert_equal 5.2, loan.interest_rate.to_f
    assert loan.variable_rate_schedule.blank?, "a fixed loan grew a schedule"
  end

  test "a locked schedule is not written" do
    loan = loan_with(interest_rate: 4.5, rate_type: "variable")
    loan.lock_attr!(:variable_rate_schedule)
    payload(type: "variable", percentage: 5.2)

    process_as_of(Date.new(2026, 1, 15))

    loan.reload
    assert loan.variable_rate_schedule.blank?
    assert_equal 4.5, loan.interest_rate.to_f
  end

  # CodeRabbit on #247: the variable path is two saves, the terms and then the
  # dated rate. Before #223 they were one save, so a refused rate took the
  # terms back with it; split, a reclassification to variable could land while
  # the rate that came with it was refused.
  test "a move to variable whose rate row is refused changes nothing" do
    loan = loan_with(interest_rate: 4.5, rate_type: "fixed")
    writer = PlaidAccount::Liabilities::MortgageProcessor.new(@plaid_account.reload, as_of: Date.new(2026, 1, 15))

    assert_difference "DebugLogEntry.count", 1, "the refusal must still be reported" do
      writer.send(:write_loan_terms, rate_type: "variable", interest_rate: 150)
    end

    assert_equal "fixed", writer.send(:account).loan.rate_type,
                 "the rolled-back reclassification is still on the writer's loan in memory"
    loan.reload
    assert_equal "fixed", loan.rate_type, "the reclassification landed without its rate"
    assert_equal 4.5, loan.interest_rate.to_f
    assert loan.variable_rate_schedule.blank?
    assert_not DataEnrichment.exists?(enrichable: loan, attribute_name: "rate_type", source: "plaid")
  end

  test "an error between the terms and the rate leaves the terms unwritten" do
    loan = loan_with(interest_rate: 4.5, rate_type: "fixed")
    writer = PlaidAccount::Liabilities::MortgageProcessor.new(@plaid_account.reload, as_of: Date.new(2026, 1, 15))
    Loan.any_instance.stubs(:variable_rate_update_for).raises(ActiveRecord::StatementInvalid, "interrupted")

    assert_raises(ActiveRecord::StatementInvalid) do
      writer.send(:write_loan_terms, rate_type: "variable", interest_rate: 5.2)
    end

    assert_equal "fixed", loan.reload.rate_type
  end

  test "a move to variable with an acceptable rate still lands both" do
    loan = loan_with(interest_rate: 4.5, rate_type: "fixed")
    writer = PlaidAccount::Liabilities::MortgageProcessor.new(@plaid_account.reload, as_of: Date.new(2026, 1, 15))

    writer.send(:write_loan_terms, rate_type: "variable", interest_rate: 5.2)

    loan.reload
    assert_equal "variable", loan.rate_type
    assert_equal({ "2026-01-15" => 5.2 }, loan.variable_rate_schedule)
  end

  private
    def loan_with(**attrs)
      loan = @plaid_account.current_account.loan
      loan.update!(attrs)
      loan
    end

    def payload(**interest_rate)
      @plaid_account.update!(raw_liabilities_payload: { mortgage: { interest_rate: interest_rate } })
    end

    def process
      PlaidAccount::Liabilities::MortgageProcessor.new(@plaid_account.reload).process
    end

    def process_as_of(date)
      PlaidAccount::Liabilities::MortgageProcessor.new(@plaid_account.reload, as_of: date).process
    end
end
