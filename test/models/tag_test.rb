require "test_helper"

class TagTest < ActiveSupport::TestCase
  test "replace and destroy does not double-tag an object that already carries the replacement" do
    old_tag = tags(:one)
    new_tag = tags(:two)

    # The taggings fixtures give transaction one both tags: without the
    # skip in replace_and_destroy! (and with no index to refuse it), the
    # merge would leave it tagged twice with the replacement.
    txn = transactions(:one)
    assert_equal 2, txn.taggings.count

    assert_difference "Tag.count", -1, "Tagging.count", -1 do
      old_tag.replace_and_destroy!(new_tag)
    end

    txn.reload
    assert_equal 1, txn.taggings.count
    assert_equal [ new_tag ], txn.tags
  end

  test "rejects the reserved Untagged filter sentinel as a name" do
    tag = families(:dylan_family).tags.new(name: Tag::UNTAGGED_FILTER_VALUE, color: "#e99537")

    assert_not tag.valid?
    assert_includes tag.errors[:name], "is reserved"
  end

  test "filter_value returns the sentinel for the synthetic Untagged tag and the name for real tags" do
    assert_equal Tag::UNTAGGED_FILTER_VALUE, Tag.untagged.filter_value
    assert_equal tags(:one).name, tags(:one).filter_value
  end
end
