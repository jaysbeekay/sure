# frozen_string_literal: true

require "test_helper"

class RedbarkItem::SyncerTest < ActiveSupport::TestCase
  setup do
    @redbark_item = redbark_items(:one)
    @redbark_account = redbark_accounts(:savings_account)
    @family = @redbark_item.family

    account = @family.accounts.create!(
      name: "Mortgage", balance: 400_000, currency: "AUD",
      accountable: Loan.new(rate_type: "variable", interest_rate: 6.25)
    )
    @redbark_account.ensure_account_provider!(account)

    @syncer = RedbarkItem::Syncer.new(@redbark_item)
  end

  # A sync reads the bank in one phase and acts on what it read in the next.
  # RedbarkAccount::LoanDetailsProcessor decides whether a stored snapshot
  # belongs to the sync now running by comparing the stamp the import wrote
  # against the date the processing was given. If those two come from separate
  # readings of the clock, a sync that fetches at 23:59 and processes at 00:00
  # discards the snapshot it has just stored, and the rate change in it is lost
  # until the bank happens to move the rate again (found on the #213 sweep).
  #
  # Asserting the two agree is the whole of it: one reading cannot disagree
  # with itself, two readings can.
  test "the account details stamp and the processing date come from one clock" do
    stamped = nil
    dated = nil

    @redbark_item.expects(:import_latest_redbark_data).with { |**kwargs|
      stamped = kwargs[:fetched_at]
      true
    }.returns({})

    @redbark_item.expects(:process_accounts).with { |**kwargs|
      dated = kwargs[:as_of]
      true
    }.returns([])

    @syncer.perform_sync(mock_sync)

    assert_kind_of Date, dated, "the processing phase was not given a date at all"
    assert_not_nil stamped, "the import phase was not given a clock to stamp with"
    assert_equal stamped.to_date, dated,
                 "the import stamped one date and the processing dated its findings by another"
  end

  private

    def mock_sync
      sync = mock("sync")
      sync.stubs(:respond_to?).with(:status_text).returns(true)
      sync.stubs(:respond_to?).with(:sync_stats).returns(true)
      sync.stubs(:sync_stats).returns({})
      sync.stubs(:created_at).returns(Time.current)
      sync.stubs(:window_start_date).returns(nil)
      sync.stubs(:window_end_date).returns(nil)
      sync.stubs(:update!)
      sync
    end
end
