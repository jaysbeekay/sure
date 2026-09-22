require "test_helper"

class Tag::DeletionsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @user = users(:family_admin)
    @tag = tags(:one)
  end

  test "should get new" do
    get new_tag_deletion_url(@tag)
    assert_response :success
  end

  # This test used to assert that the replacement gained one transaction per
  # transaction the old tag had. The fixture's only tagged transaction already
  # carries BOTH tags, so what it was really pinning was the duplicate row
  # #202 exists to remove -- the merge added a second (tag two, transaction
  # one) tagging and the count went up. With the dedupe in place it does not,
  # and the assertion failed. The expectation was wrong, not the change.
  #
  # Both branches are covered now, because the fixture alone only exercises
  # the skip: an object that already carries the replacement must not be
  # tagged twice, and an object carrying only the old tag must still be moved.
  test "create with replacement moves what needs moving and duplicates nothing" do
    replacement_tag = tags(:two)

    already_carrying = transactions(:one)
    assert_equal [ @tag.id, replacement_tag.id ].sort, already_carrying.tags.map(&:id).sort,
                 "the fixture must carry both tags, or the skip is never exercised"

    moved = transactions(:transfer_out)
    moved.taggings.create!(tag: @tag)

    assert_difference -> { Tag.count } => -1, -> { Tagging.count } => -1 do
      post tag_deletions_url(@tag), params: { replacement_tag_id: replacement_tag.id }
    end

    assert_equal [ replacement_tag ], already_carrying.reload.tags,
                 "an object already carrying the replacement was tagged with it twice"
    assert_equal [ replacement_tag ], moved.reload.tags,
                 "an object carrying only the old tag lost it instead of being moved"
  end

  test "create without replacement" do
    affected_transactions = @tag.transactions

    assert affected_transactions.count > 0

    assert_difference -> { Tag.count } => -1, -> { Tagging.count } => affected_transactions.count * -1 do
      post tag_deletions_url(@tag)
    end
  end

  test "create with invalid or cross-family tag_id returns not found" do
    other_family_tag = families(:empty).tags.create!(name: "Other family tag")

    assert_no_difference -> { Tag.count } do
      post tag_deletions_url(tag_id: other_family_tag.id)
    end

    assert_response :not_found
  end

  test "create with invalid replacement_tag_id returns not found" do
    assert_no_difference -> { Tag.count } do
      post tag_deletions_url(@tag), params: { replacement_tag_id: "missing" }
    end

    assert_response :not_found
  end
end
