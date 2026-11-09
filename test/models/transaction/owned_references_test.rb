require "test_helper"

class Transaction::OwnedReferencesTest < ActiveSupport::TestCase
  include ForeignFamilyTestHelper

  setup do
    @user = users(:family_admin)
    @references = Transaction::OwnedReferences.new(@user.family, @user)
  end

  test "loads no reference sets when a form sends no reference ids" do
    Entry::SplitReferences.expects(:for_user).never

    assert_empty @references.unusable({ name: "Renamed", category_id: "", tag_ids: [ "" ] })
    assert_empty @references.unusable(nil)
  end

  test "reports the ids the family may not use, and none it may" do
    unusable = @references.unusable({ category_id: foreign_category.id, merchant_id: merchants(:netflix).id, tag_ids: [ tags(:one).id, foreign_tag.id ] })

    assert_equal [ [ :category, foreign_category.id ], [ :tag, foreign_tag.id ] ], unusable
  end

  test "an id the transaction already holds is usable" do
    transaction = transactions(:one)
    transaction.update_columns(category_id: foreign_category.id)

    assert_empty @references.unusable({ category_id: foreign_category.id }, transaction: transaction)
    assert_equal [ [ :category, foreign_category.id ] ], @references.unusable({ category_id: foreign_category.id })
  end
end
