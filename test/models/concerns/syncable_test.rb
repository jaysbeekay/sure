require "test_helper"

class SyncableTest < ActiveSupport::TestCase
  setup do
    @item = kraken_items(:one)
  end

  test "latest_sync_stats returns the newest sync's stats" do
    @item.syncs.create!(status: "completed", completed_at: 2.days.ago, created_at: 2.days.ago, sync_stats: { "tx_seen" => 1 })
    @item.syncs.create!(status: "completed", completed_at: 1.day.ago, created_at: 1.day.ago, sync_stats: { "tx_seen" => 7 })

    assert_equal({ "tx_seen" => 7 }, @item.latest_sync_stats)
  end

  test "latest_sync_stats is empty for an item that has never synced" do
    assert_empty @item.syncs

    assert_equal({}, @item.latest_sync_stats)
  end

  test "latest_sync_stats is empty when the latest sync recorded no stats" do
    @item.syncs.create!(status: "completed", completed_at: 2.days.ago, created_at: 2.days.ago, sync_stats: { "tx_seen" => 1 })
    @item.syncs.create!(status: "pending", created_at: 1.day.ago)

    assert_equal({}, @item.latest_sync_stats)
  end
end
