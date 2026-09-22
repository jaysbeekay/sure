# frozen_string_literal: true

require "test_helper"

# Issue #142 (L45) phase 1: a loan's rate, read from what the bank reported.
#
# The acceptance rows these cover are numbered on the issue's triage plan and
# its amendment. Every rate in a payload is a FRACTION as a string, the way
# `/v1/account-details` reports it: "0.0675" is 6.75%.
class RedbarkAccount::LoanDetailsProcessorTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @redbark_account = redbark_accounts(:savings_account)
    @family = @redbark_account.redbark_item.family
    @as_of = Date.new(2026, 9, 21)

    @account = @family.accounts.create!(
      name: "Mortgage",
      balance: 400_000,
      currency: "AUD",
      accountable: Loan.new(rate_type: "variable", interest_rate: 6.25, term_months: 360)
    )
    @loan = @account.accountable

    @redbark_account.ensure_account_provider!(@account)
    @redbark_account.reload
  end

  # Row 1: the detection that is the whole point of the slice.
  test "a reported rate that differs from the rate in force is recorded on the sync date" do
    detail lendingRate: "0.0675"

    process

    assert_equal({ "2026-09-21" => BigDecimal("6.75") }, rates,
                 "the detected rate was not recorded against the injected sync date")
  end

  # Row 13: the date is the caller's, not the clock's. Travelling the clock
  # away from `as_of` is the only way to tell the two apart.
  test "the row is keyed by the injected date, never by today" do
    detail lendingRate: "0.0675"

    travel_to Date.new(2026, 12, 25) do
      process
    end

    assert_equal [ "2026-09-21" ], schedule.keys,
                 "the processor read the clock instead of the date it was given"
  end

  # Row 2: the same payload on two syncs is one change, not two -- and the
  # second must not queue another rebuild.
  test "the same reported rate twice records one row and queues one rebuild" do
    detail lendingRate: "0.0675"

    assert_enqueued_jobs 1, only: LoanAmortizationRebuildJob do
      process
    end

    assert_no_enqueued_jobs only: LoanAmortizationRebuildJob do
      RedbarkAccount::LoanDetailsProcessor.new(@redbark_account.reload, as_of: @as_of + 1).process
    end

    assert_equal 1, schedule.size, "a second sync recorded the same rate again"
  end

  # Row 3.
  test "a reported rate equal to the rate in force records nothing" do
    detail lendingRate: "0.0625"

    process

    assert_empty schedule, "a rate that had not moved was recorded as a change"
  end

  # Rows 4 and 10: a fixed loan's rate does not move, so a bank disagreeing is
  # something to surface rather than something to write.
  test "a different rate on a fixed loan writes nothing and is logged" do
    @loan.update!(rate_type: "fixed")
    detail lendingRate: "0.0675"

    assert_difference -> { DebugLogEntry.count }, 1 do
      process
    end

    @loan.reload
    assert_empty schedule
    assert_equal 6.25, @loan.interest_rate.to_f, "a fixed loan's base rate was overwritten"
    assert_equal "fixed", @loan.rate_type
  end

  # Row 5: a hand-edited schedule stops detection for that loan. The lock is
  # what the form sets when a user edits the rows.
  test "a locked schedule is not added to" do
    @loan.lock_attr!(:variable_rate_schedule)
    detail lendingRate: "0.0675"

    process

    assert_empty schedule, "a locked schedule was written by the provider"
  end

  # Row 6, second half: no headline rate, one VARIABLE entry -> use it.
  test "a single variable entry is used when there is no headline rate" do
    detail lendingRates: [ { "rateType" => "VARIABLE", "rate" => "0.0699" } ]

    process

    assert_equal({ "2026-09-21" => BigDecimal("6.99") }, rates)
  end

  # Row 6, first half: several candidates -> record nothing, say so.
  test "several variable entries record nothing and are logged" do
    detail lendingRates: [
      { "rateType" => "VARIABLE", "rate" => "0.0699" },
      { "rateType" => "VARIABLE", "rate" => "0.0725" }
    ]

    assert_difference -> { DebugLogEntry.count }, 1 do
      process
    end

    assert_empty schedule
  end

  # Amendment correction 6: a tiered rate is several rates wearing one entry,
  # and the payload does not say which band the account sits in.
  test "a tiered variable entry records nothing" do
    detail lendingRates: [ {
      "rateType" => "VARIABLE", "rate" => "0.0699",
      "tiers" => [ { "name" => "Balance tier", "minimumValue" => 0, "maximumValue" => 250_000 } ]
    } ]

    process

    assert_empty schedule, "a rate that applies to one balance band was recorded as the loan's rate"
  end

  # Rows 12a-c: a loan whose rate was never recorded is not a loan whose rate
  # just moved.
  test "a first sighting sets the base rate and records no change" do
    @loan.update!(interest_rate: nil)
    detail lendingRate: "0.0675"

    process

    @loan.reload
    assert_equal 6.75, @loan.interest_rate.to_f
    assert_empty schedule, "a first sighting invented a change that never happened"
  end

  test "a first sighting leaves a locked base rate untouched" do
    @loan.update!(interest_rate: nil)
    @loan.lock_attr!(:interest_rate)
    detail lendingRate: "0.0675"

    process

    assert_nil @loan.reload.interest_rate
  end

  # Row 11.
  test "a blank rate type becomes variable when the bank calls the product variable" do
    @loan.update!(rate_type: nil, interest_rate: nil)
    detail lendingRates: [ { "rateType" => "VARIABLE", "rate" => "0.0699" } ]

    process

    @loan.reload
    assert_equal "variable", @loan.rate_type
    assert_equal 6.99, @loan.interest_rate.to_f
  end

  # Row 17: provenance, so a user can see where a row came from.
  test "a detected change records its provenance as redbark" do
    detail lendingRate: "0.0675"

    process

    enrichment = DataEnrichment.find_by(enrichable: @loan, attribute_name: "variable_rate_schedule")
    assert_not_nil enrichment, "no provenance was recorded for the detected change"
    assert_equal "redbark", enrichment.source
  end

  # Row 8.
  test "loan terms are filled only where blank" do
    @loan.update!(start_date: nil, term_months: nil, initial_balance: nil)
    detail(
      lendingRate: "0.0625",
      loanDetails: {
        "originalStartDate" => "2020-03-15", "loanEndDate" => "2050-03-15",
        "originalLoanAmount" => "512000.00"
      }
    )

    process

    @loan.reload
    assert_equal Date.new(2020, 3, 15), @loan.start_date
    assert_equal 360, @loan.term_months
    assert_equal 512_000, @loan.initial_balance.to_f
  end

  test "loan terms already set are left alone" do
    @loan.update!(start_date: Date.new(2019, 1, 1), term_months: 240, initial_balance: 100)
    detail(
      lendingRate: "0.0625",
      loanDetails: {
        "originalStartDate" => "2020-03-15", "loanEndDate" => "2050-03-15",
        "originalLoanAmount" => "512000.00"
      }
    )

    process

    @loan.reload
    assert_equal Date.new(2019, 1, 1), @loan.start_date
    assert_equal 240, @loan.term_months
    assert_equal 100, @loan.initial_balance.to_f
  end

  # A snapshot this sync did not refresh is a previous answer, not a current
  # one. Acting on it writes last week's rate back over a correction the user
  # has made since -- as though the bank had just reported it (cubic, #213).
  test "a snapshot from an earlier sync is not acted on" do
    detail lendingRate: "0.0675", fetched_at: (@as_of - 3).to_time

    process

    assert_empty schedule,
                 "a stale snapshot was recorded as though the bank had just reported it"
  end

  test "a snapshot refreshed today is acted on" do
    detail lendingRate: "0.0675", fetched_at: @as_of.to_time

    process

    assert_equal({ "2026-09-21" => BigDecimal("6.75") }, rates)
  end

  # The loan stores rates quantized to three decimals
  # (Loan#quantize_variable_rate_schedule). Reading four and comparing against
  # three makes an unchanged rate look changed EVERY sync, so the loan would
  # gain a row a day for ever (cubic, #213).
  test "a rate with more precision than the loan stores does not re-record every sync" do
    @loan.update!(variable_rate_schedule: { "2026-09-01" => 6.499 })
    detail lendingRate: "0.064994"

    process

    assert_equal [ "2026-09-01" ], schedule.keys,
                 "the same rate was recorded again because it was compared at a precision the loan does not keep"
  end

  # Row 14: an account the provider reported nothing for.
  test "no payload writes nothing and does not raise" do
    @redbark_account.update!(raw_account_details_payload: nil)

    assert_nothing_raised { process }
    assert_empty schedule
  end

  # Row 16: a shape that is neither absent nor an array.
  test "a malformed lendingRates shape writes nothing, does not raise, and is logged" do
    detail lendingRates: "not-an-array"

    assert_difference -> { DebugLogEntry.count }, 1 do
      assert_nothing_raised { process }
    end

    assert_empty schedule
  end

  # Row 15: the model refuses 150%, and the sync survives it.
  test "a rate the model refuses is logged rather than raised" do
    detail lendingRate: "1.5"

    assert_difference -> { DebugLogEntry.count }, 1 do
      assert_nothing_raised { process }
    end

    assert_empty schedule, "a rate outside the valid range was recorded"
  end

  # Row 9: the detected row reaches the engine, for a cut as well as a rise.
  test "a detected cut re-amortises from the detection date" do
    detail lendingRate: "0.0525"

    process

    events = Loan::RateResolver.for(@loan.reload)
                               .re_amortisation_events(Date.new(2026, 1, 1), Date.new(2027, 1, 1))

    assert_includes events.map { |event| event[:date] }, Date.new(2026, 9, 21),
                    "the detected change did not reach the rate resolver, so nothing re-amortises"
  end

  private
    # Stamped as fetched on the sync's own date, which is what the importer
    # does on a successful refresh. `fetched_at:` lets a test make the snapshot
    # stale on purpose.
    def detail(fetched_at: @as_of.to_time, **payload)
      @redbark_account.update!(
        raw_account_details_payload: { "accountId" => @redbark_account.redbark_account_id }.merge(
          payload.transform_keys(&:to_s)
        ),
        account_details_fetched_at: fetched_at
      )
    end

    def process
      RedbarkAccount::LoanDetailsProcessor.new(@redbark_account, as_of: @as_of).process
    end

    def schedule
      (@loan.reload.variable_rate_schedule || {}).stringify_keys
    end

    # The model quantizes what it stores (Loan#quantize_variable_rate_schedule),
    # so assert the VALUE rather than the representation the processor passed in.
    def rates
      schedule.transform_values { |rate| BigDecimal(rate.to_s) }
    end
end
