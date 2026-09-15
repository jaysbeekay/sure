require "test_helper"

# track_stale_unmatched_pending counts stale pending entries that have no posted
# match. It decides "pending" as Transaction#pending? does, across every pending
# provider, like the stale-pending exclusion it is paired with -- which runs
# immediately AFTER it, since excluding first would empty this count's
# candidate set. See SimplefinItem::Importer#run_pending_reconciliation.
class SimplefinItem::ImporterStaleUnmatchedPendingTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:empty)
    @item = SimplefinItem.create!(family: @family, name: "SF Conn", access_url: "https://example.com/access")
    @account = @family.accounts.create!(name: "SF Checking", balance: 0, currency: "USD", accountable: Depository.new)
    @importer = SimplefinItem::Importer.new(@item, simplefin_provider: mock(), sync: Sync.create!(syncable: @item))
  end

  test "counts a stale entry whose flag a boolean cast cannot parse, without recording an error" do
    stale_entry("simplefin" => { "pending" => "maybe" })

    track

    assert_nil stats["reconciliation_errors"]
    assert_equal 1, stats["stale_unmatched_pending"]
  end

  test "counts a stale entry flagged \"no\", which pending? calls pending" do
    stale_entry("simplefin" => { "pending" => "no" })

    track

    assert_equal 1, stats["stale_unmatched_pending"]
  end

  test "counts a stale entry pending under any provider, not only SimpleFIN and Plaid" do
    stale_entry("lunchflow" => { "pending" => true })

    track

    assert_equal 1, stats["stale_unmatched_pending"]
  end

  test "does not count stale entries that are not pending" do
    stale_entry("plaid" => { "pending" => "false" })
    stale_entry({})

    track

    assert_nil stats["reconciliation_errors"]
    assert_nil stats["stale_unmatched_pending"]
  end

  # The tests above call track_stale_unmatched_pending directly, which is how
  # the count being permanently zero in production went unnoticed: the stale
  # exclusion runs in the same pass and flips `excluded: true` on a superset of
  # what the count asks for. These two go through run_pending_reconciliation,
  # the sequence import_account actually runs, so the order is under test.
  test "the import sequence counts a stale unmatched entry before excluding it" do
    stale_entry("simplefin" => { "pending" => true })

    @importer.send(:run_pending_reconciliation, @account)

    assert_equal 1, stats["stale_unmatched_pending"]
    assert_equal 1, stats["stale_pending_excluded"]
  end

  test "the import sequence does not re-count an entry a previous sync excluded" do
    entry = stale_entry("simplefin" => { "pending" => true })
    entry.update!(excluded: true)

    @importer.send(:run_pending_reconciliation, @account)

    assert_nil stats["stale_unmatched_pending"]
    assert_nil stats["stale_pending_excluded"]
  end

  private

    def stale_entry(extra)
      create_transaction(account: @account, amount: 10, date: 10.days.ago.to_date).tap do |entry|
        entry.entryable.update!(extra: extra)
      end
    end

    def track
      @importer.send(:track_stale_unmatched_pending, @account)
    end

    def stats
      @importer.send(:stats)
    end
end
