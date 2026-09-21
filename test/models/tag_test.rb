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

    # The array form, because `assert_difference "a", -1, "b", -1` does not
    # mean what it reads as: with a String first argument Rails binds the
    # second argument as the difference and the third as the MESSAGE, so
    # "Tagging.count" was never asserted at all (raised by cubic).
    assert_difference [ "Tag.count", "Tagging.count" ], -1 do
      old_tag.replace_and_destroy!(new_tag)
    end

    txn.reload
    assert_equal 1, txn.taggings.count
    assert_equal [ new_tag ], txn.tags
  end

  # The skip is expressed as `where.not(taggable_id: <subquery>)`, which
  # compiles to NOT IN. A NOT IN whose set contains NULL is NULL for every
  # row, so one replacement tagging with a NULL taggable_id would make the
  # merge match nothing and move no tags at all -- silently, since the tag is
  # then destroyed and its taggings go with it. The columns are nullable at
  # the database level, so the subquery has to exclude them.
  test "a replacement tagging with no taggable does not stop the merge" do
    old_tag = tags(:one)
    new_tag = tags(:two)

    # A transaction carrying ONLY the old tag: the fixture's transaction one
    # carries both, so on its own it exercises the skip and never notices a
    # merge that moved nothing.
    moved = transactions(:transfer_out)
    moved.taggings.create!(tag: old_tag)

    # A row the database allows and the model does not.
    Tagging.insert_all!([ {
      tag_id: new_tag.id, taggable_id: nil, taggable_type: nil,
      created_at: Time.current, updated_at: Time.current
    } ])

    old_tag.replace_and_destroy!(new_tag)

    assert_equal [ new_tag ], moved.reload.tags,
                 "the merge moved nothing: a NULL in the NOT IN set swallowed every row"
  end

  # The partial index keys on (tag_id, taggable_type, taggable_id), and
  # Postgres's default treats two NULL taggable_types as distinct keys -- so
  # without NULLS NOT DISTINCT the index admits exactly the duplicate it was
  # added to refuse whenever the type is absent (raised by cubic).
  test "the index refuses a duplicate whose taggable_type is NULL" do
    row = {
      tag_id: tags(:one).id, taggable_id: transactions(:transfer_out).id,
      taggable_type: nil, created_at: Time.current, updated_at: Time.current
    }

    Tagging.insert_all!([ row ])

    assert_raises ActiveRecord::RecordNotUnique do
      Tagging.insert_all!([ row ])
    end
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
