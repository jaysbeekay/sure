require "test_helper"

class TagTest < ActiveSupport::TestCase
  test "replace and destroy moves the tag and tags nothing twice" do
    old_tag = tags(:one)
    new_tag = tags(:two)

    # The fixture transaction already carries both tags; this one carries
    # only the tag being replaced.
    already_tagged = transactions(:one)
    moved = transactions(:transfer_out)
    moved.taggings.create!(tag: old_tag)

    assert_difference [ "Tag.count", "Tagging.count" ], -1 do
      old_tag.replace_and_destroy!(new_tag)
    end

    assert_equal [ new_tag ], already_tagged.reload.tags.to_a
    assert_equal [ new_tag ], moved.reload.tags.to_a
  end

  # destroy! removes the taggings association it holds. If a caller loaded it
  # before the merge, that list still names the rows the merge just moved.
  test "replace and destroy keeps the moved rows when the source taggings were loaded first" do
    old_tag = tags(:one)
    new_tag = tags(:two)
    moved = transactions(:transfer_out)
    moved_tagging = moved.taggings.create!(tag: old_tag)
    old_tag.taggings.load

    assert_difference "Tagging.count", -1 do
      old_tag.replace_and_destroy!(new_tag)
    end

    assert Tagging.exists?(moved_tagging.id)
    assert_equal [ new_tag ], moved.reload.tags.to_a
  end

  # The unique index treats a missing taggable_type as a value, so the merge
  # has to as well, or it moves the row into a duplicate and fails.
  test "replace and destroy skips a row with no taggable type that the replacement already has" do
    old_tag = tags(:one)
    new_tag = tags(:two)
    taggable_id = transactions(:transfer_out).id
    Tagging.insert_all!([ old_tag, new_tag ].map do |tag|
      { tag_id: tag.id, taggable_id: taggable_id, taggable_type: nil, created_at: Time.current, updated_at: Time.current }
    end)

    old_tag.replace_and_destroy!(new_tag)

    assert_equal [ new_tag.id ], Tagging.where(taggable_id: taggable_id).pluck(:tag_id)
  end

  test "ids_with_transactions lists only the given tags that are on a transaction" do
    family = families(:dylan_family)
    ids = Tag.ids_with_transactions(family: family, tag_ids: [ tags(:one).id, tags(:two).id, tags(:three).id ])

    assert_equal({ tags(:one).id => true, tags(:two).id => true }, ids)
    assert_equal({}, Tag.ids_with_transactions(family: families(:empty), tag_ids: [ tags(:one).id ]))
    assert_equal({}, Tag.ids_with_transactions(family: family, tag_ids: []))
  end

  # The unique index folds a missing taggable_type to '', so the merge must
  # treat a NULL type and an empty one as the same object too, or moving the
  # row would hit the index.
  test "replace and destroy treats a missing and an empty taggable type as the same object" do
    old_tag = tags(:one)
    new_tag = tags(:two)
    taggable_id = transactions(:transfer_out).id
    Tagging.insert_all!([
      { tag_id: old_tag.id, taggable_id: taggable_id, taggable_type: nil, created_at: Time.current, updated_at: Time.current },
      { tag_id: new_tag.id, taggable_id: taggable_id, taggable_type: "", created_at: Time.current, updated_at: Time.current }
    ])

    old_tag.replace_and_destroy!(new_tag)

    assert_equal [ new_tag.id ], Tagging.where(taggable_id: taggable_id).pluck(:tag_id)
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
end
