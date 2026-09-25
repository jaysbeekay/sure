require "test_helper"

class EnrichableTest < ActiveSupport::TestCase
  setup do
    @enrichable = accounts(:depository)
  end

  test "can enrich multiple attributes" do
    assert_difference "DataEnrichment.count", 2 do
      @enrichable.enrich_attributes({ name: "Updated Checking", balance: 6_000 }, source: "plaid")
    end

    assert_equal "Updated Checking", @enrichable.name
    assert_equal 6_000, @enrichable.balance.to_d
  end

  test "can enrich a single attribute" do
    assert_difference "DataEnrichment.count", 1 do
      @enrichable.enrich_attribute(:name, "Single Update", source: "ai")
    end

    assert_equal "Single Update", @enrichable.name
  end

  test "can lock an attribute" do
    refute @enrichable.locked?(:name)

    @enrichable.lock_attr!(:name)
    assert @enrichable.locked?(:name)
  end

  test "can unlock an attribute" do
    @enrichable.lock_attr!(:name)
    assert @enrichable.locked?(:name)

    @enrichable.unlock_attr!(:name)
    refute @enrichable.locked?(:name)
  end

  test "can lock saved attributes" do
    @enrichable.name = "User Override"
    @enrichable.balance = 1_234
    @enrichable.save!

    @enrichable.lock_saved_attributes!

    assert @enrichable.locked?(:name)
    assert @enrichable.locked?(:balance)
  end

  test "does not enrich locked attributes" do
    original_name = @enrichable.name

    @enrichable.lock_attr!(:name)

    assert_no_difference "DataEnrichment.count" do
      @enrichable.enrich_attribute(:name, "Should Not Change", source: "plaid")
    end

    assert_equal original_name, @enrichable.reload.name
  end

  test "enrichable? reflects lock state" do
    assert @enrichable.enrichable?(:name)

    @enrichable.lock_attr!(:name)

    refute @enrichable.enrichable?(:name)
  end

  test "enrichable scope includes and excludes records based on lock state" do
    # Initially, the record should be enrichable for :name
    assert_includes Account.enrichable(:name), @enrichable

    @enrichable.lock_attr!(:name)

    refute_includes Account.enrichable(:name), @enrichable
  end

  # Issue #224 (option 1, correction b): DataEnrichment is logged only AFTER
  # a successful save on an existing record. The three tests below pin each
  # branch of the new guard so any regression to the pre-fix behavior
  # (log_enrichment called inside the setter loop, before save) is caught
  # by CI.

  test "does not log enrichment when save is refused" do
    # The pre-fix code called log_enrichment inside the setter loop BEFORE
    # save, so a refused save still produced a DataEnrichment row. Stub the
    # record's save to fail and assert the guard now skips the log. The
    # setter itself (self.name = "…") still runs in memory so the code path
    # is exercised, but no row reaches the database.
    @enrichable.stubs(:save).returns(false)

    assert_no_difference "DataEnrichment.count" do
      @enrichable.enrich_attribute(:name, "Refused Save", source: "plaid")
    end
  end

  test "does not log enrichment for a new record" do
    # Build a genuinely new (unpersisted) Enrichable model. Stub save to
    # return true so that "new-record guard" is the ONLY thing preventing
    # the log — if we let a real save run, validation/refusal would ALSO
    # yield assert_no_difference and we could not distinguish the two
    # causes. With save stubbed true and the guard in place, the pre-fix
    # code (logging before save) would have created a row; the post-fix
    # code (save_result && !was_new) must skip it.
    new_record = Account.new(
      family: families(:dylan_family),
      name: "Unsaved Account",
      balance: 0,
      currency: "USD",
    )

    assert new_record.new_record?
    new_record.stubs(:save).returns(true)

    assert_no_difference "DataEnrichment.count" do
      new_record.enrich_attribute(:name, "Still Unsaved", source: "plaid")
    end

    # Save was stubbed — no id was assigned, so the record is
    # still new from our side's point of view.
    assert new_record.new_record?
  end

  test "enriches a virtual attribute (tag_ids) on an Enrichable model and logs after save" do
    # Confidence regression for the virtual-attribute path. tag_ids comes
    # from has_many :tags, through: :taggings; it is NOT tracked by
    # previous_changes, so the code falls through to the virtual-check
    # branch. The post-fix code still logs because save on the real
    # persisted record returns true (save_result && !was_new == true).
    # transactions(:one) is ALREADY tagged with tags(:one) and tags(:two)
    # (see test/fixtures/taggings.yml), so pick the tag that is attached to
    # no transaction. That makes the refute_includes precondition true and this
    # the only tag the enrichment actually applies — the post-save logging
    # assertion then reflects a genuine new tag, not a re-application.
    txn = transactions(:one)
    tag = tags(:three)

    refute_includes txn.tag_ids, tag.id

    assert_difference "DataEnrichment.count", 1 do
      txn.enrich_attribute(:tag_ids, [ tag.id ], source: "rule")
    end

    # The tag was actually applied to the transaction.
    assert_includes txn.reload.tag_ids, tag.id

    # And the DataEnrichment row carries the right metadata.
    de = DataEnrichment.last
    assert_equal "tag_ids", de.attribute_name
    assert_equal "rule", de.source
  end
end
