require "test_helper"

class Financekit::DownstreamLockKeyTest < ActiveSupport::TestCase
  # The key is a coordination contract between worker processes, not a
  # digest anyone relies on for secrecy. A worker still running the previous
  # release and one running this release must derive the SAME key for the
  # same publisher, or both pass pg_try_advisory_lock and repeat the
  # downstream fan-out during a rolling deploy (CodeRabbit on #243). So the
  # value is pinned: changing the derivation must be a deliberate, drained
  # deploy, and this test is where that decision shows up.
  test "the advisory lock key for a publisher is stable across releases" do
    item = Struct.new(:id).new("00000000-0000-4000-8000-000000000235")
    downstream = Financekit::Downstream.new(item, FinancekitBatch.none)

    assert_equal 2897850380234485413, downstream.send(:advisory_lock_key)
  end
end
