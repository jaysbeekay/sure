require "test_helper"

class AccountShareTest < ActiveSupport::TestCase
  setup do
    @admin = users(:family_admin)
    @member = users(:family_member)
    @account = accounts(:depository)
  end

  test "valid share" do
    # Use an account that doesn't already have a share with member
    account = accounts(:investment)
    account.account_shares.where(user: @member).destroy_all
    share = AccountShare.new(account: account, user: @member, permission: "read_only")
    assert share.valid?
  end

  test "invalid permission" do
    share = AccountShare.new(account: @account, user: @member, permission: "invalid")
    assert_not share.valid?
    assert_includes share.errors[:permission], "is not included in the list"
  end

  test "cannot share with account owner" do
    share = AccountShare.new(account: @account, user: @admin, permission: "read_only")
    assert_not share.valid?
    assert_includes share.errors[:user], "is already the owner of this account"
  end

  test "cannot duplicate share for same user and account" do
    # depository already shared with member via fixture
    duplicate = AccountShare.new(account: @account, user: @member, permission: "read_only")
    assert_not duplicate.valid?
  end

  test "permission helper methods" do
    share = AccountShare.new(permission: "full_control")
    assert share.full_control?
    assert_not share.read_write?
    assert_not share.read_only?
    assert share.can_annotate?
    assert share.can_edit?

    share.permission = "read_write"
    assert share.read_write?
    assert share.can_annotate?
    assert_not share.can_edit?

    share.permission = "read_only"
    assert share.read_only?
    assert_not share.can_annotate?
    assert_not share.can_edit?
  end

  test "cannot share with user from different family" do
    other_user = users(:empty)
    share = AccountShare.new(account: @account, user: other_user, permission: "read_only")
    assert_not share.valid?
    assert_includes share.errors[:user], "must be in the same family"
  end

  test "removing a share expires that account's stale-valuation insight" do
    property = accounts(:property)
    property.share_with!(@member, permission: "read_only")
    nudge = stale_valuation_insight_for(property)
    other = stale_valuation_insight_for(accounts(:vehicle))

    property.unshare_with!(@member)

    assert nudge.reload.expired?
    assert other.reload.active?, "only the unshared account's card is expired"
  end

  # Only a card still in the feed is expired; one the user already
  # acknowledged keeps that status.
  test "removing a share leaves an acknowledged stale-valuation insight acknowledged" do
    property = accounts(:property)
    property.share_with!(@member, permission: "read_only")
    nudge = stale_valuation_insight_for(property)
    nudge.acknowledge!

    property.unshare_with!(@member)

    assert nudge.reload.acknowledged?
  end

  test "removing a share leaves other insight types about the account alone" do
    property = accounts(:property)
    property.share_with!(@member, permission: "read_only")
    # Same account in the metadata, different type: only the type tells them apart.
    unrelated = property.family.insights.create!(
      insight_type: "idle_cash", priority: "low", status: "active",
      title: "Idle cash", body: "Body", metadata: { account_id: property.id },
      dedup_key: "idle_cash:#{property.id}:#{Date.current.strftime("%Y-%m")}"
    )

    property.unshare_with!(@member)

    assert unrelated.reload.active?
  end

  test "adding a share expires nothing" do
    nudge = stale_valuation_insight_for(accounts(:property))

    accounts(:property).share_with!(@member, permission: "read_only")

    assert nudge.reload.active?
  end

  private
    def stale_valuation_insight_for(account)
      account.family.insights.create!(
        insight_type: "stale_valuation", priority: "low", status: "active",
        title: "#{account.name} needs a new value", body: "Body",
        metadata: { account_id: account.id, last_valued_on: 100.days.ago.to_date.iso8601 },
        dedup_key: "stale_valuation:#{account.id}:#{Date.current.strftime("%Y-%m")}"
      )
    end
end
