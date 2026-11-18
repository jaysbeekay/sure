require "test_helper"

class SyncableTest < ActiveSupport::TestCase
  setup do
    @item = kraken_items(:one)
  end

  test "latest_sync_stats returns the newest sync's stats" do
    # The newer sync goes in first, so insertion order would pick the wrong one.
    @item.syncs.create!(status: "completed", completed_at: 1.day.ago, created_at: 1.day.ago, sync_stats: { "tx_seen" => 7 })
    @item.syncs.create!(status: "completed", completed_at: 2.days.ago, created_at: 2.days.ago, sync_stats: { "tx_seen" => 1 })

    assert_equal({ "tx_seen" => 7 }, @item.latest_sync_stats)
  end

  test "latest_sync_stats breaks a created_at tie by the higher id, loaded or not" do
    # The winner is inserted between the others, so neither first nor last inserted is right.
    at = 1.day.ago
    @item.syncs.create!(id: "00000000-0000-4000-8000-000000000000", status: "completed", completed_at: at, created_at: at, sync_stats: { "tx_seen" => 2 })
    @item.syncs.create!(id: "ffffffff-ffff-4fff-bfff-ffffffffffff", status: "completed", completed_at: at, created_at: at, sync_stats: { "tx_seen" => 9 })
    @item.syncs.create!(id: "77777777-7777-4777-b777-777777777777", status: "completed", completed_at: at, created_at: at, sync_stats: { "tx_seen" => 5 })

    assert_equal({ "tx_seen" => 9 }, @item.reload.latest_sync_stats)
    assert_equal({ "tx_seen" => 9 }, kraken_items(:one).tap { |item| item.syncs.load }.latest_sync_stats)
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
