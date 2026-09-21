require "test_helper"

# Tags are the family-scoped half of classification. 3.3 writes asset class,
# sector and region to a GLOBALLY SHARED `securities` row; a `Tag` carries
# `family_id`, so a tagging is only reachable through the owning family's tags.
#
# That sharing is also the hazard these tests exist for: `security.tags` spans
# every family, so the obvious implementation -- `security.tags = ...` -- would
# delete other families' taggings on the same instrument.
class HoldingsTagsTest < ActionDispatch::IntegrationTest
  setup do
    sign_in users(:family_admin)
    @holding = holdings(:one)
    @security = @holding.security
    @family = users(:family_admin).family
    @tag = tags(:one)
    @other_family = users(:josh).family
    @other_tag = @other_family.tags.create!(name: "Someone else's scheme")
  end

  test "a security is tagged from the drawer, and the tag reaches it from the family" do
    patch tags_holding_path(@holding), params: { security: { tag_ids: [ @tag.id ] } }

    assert_equal [ @tag ], @security.reload.tags.to_a
    assert_includes @family.tags.find(@tag.id).securities, @security
  end

  # The disclosure test. `securities` is shared, so attaching a tag the family
  # does not own would publish that tag's NAME against an instrument other
  # families hold. Fails if the action assigns from `Tag` rather than from
  # `Current.family.tags`.
  test "a tag belonging to another family cannot be attached" do
    assert_no_difference "Tagging.count" do
      patch tags_holding_path(@holding), params: { security: { tag_ids: [ @other_tag.id ] } }
    end

    assert_empty @security.reload.tags
  end

  # The destruction test, and the reason this is not a one-line `tags=`.
  # `security.tags` is every family's tags on this row, so a wholesale
  # assignment would take the other family's tagging with it.
  test "tagging a shared security leaves another family's tags on it alone" do
    @security.taggings.create!(tag: @other_tag)

    patch tags_holding_path(@holding), params: { security: { tag_ids: [ @tag.id ] } }

    @security.reload
    assert_includes @security.tags, @tag
    assert_includes @security.tags, @other_tag,
                    "another family's tag was destroyed by this family's edit"
  end

  test "an empty selection clears this family's tags but not another family's" do
    @security.taggings.create!(tag: @tag)
    @security.taggings.create!(tag: @other_tag)

    patch tags_holding_path(@holding), params: { security: { tag_ids: [ "" ] } }

    assert_equal [ @other_tag ], @security.reload.tags.to_a
  end

  test "re-submitting the same tag does not duplicate the tagging" do
    patch tags_holding_path(@holding), params: { security: { tag_ids: [ @tag.id ] } }
    patch tags_holding_path(@holding), params: { security: { tag_ids: [ @tag.id ] } }

    assert_equal 1, @security.reload.taggings.where(tag: @tag).count
  end

  # The assertion that decides the taggable. `holdings` is a per-date snapshot
  # table -- unique on (account_id, security_id, date, currency) -- so a tagging
  # hung off a Holding would be attached to one day's row and would disappear
  # the next time balances were materialised. Hung off the Security it survives.
  test "a tag survives the next day's holding snapshot" do
    patch tags_holding_path(@holding), params: { security: { tag_ids: [ @tag.id ] } }

    tomorrow = @holding.account.holdings.create!(
      security: @security, date: Date.current + 1, qty: @holding.qty,
      price: @holding.price, amount: @holding.amount, currency: @holding.currency
    )

    assert_equal [ @tag ], tomorrow.security.tags.to_a,
                 "the tag did not survive a new snapshot row, so it is not on the security"
  end

  test "destroying a tag removes its security taggings and leaves the security" do
    @security.taggings.create!(tag: @tag)

    # Scoped to this security's taggings on purpose: the fixture tag also tags a
    # transaction, so a bare `Tagging.count` would move by more than this change
    # is responsible for and would assert the fixtures rather than the code.
    assert_difference -> { Tagging.where(taggable: @security).count }, -1 do
      @tag.destroy!
    end

    assert Security.exists?(@security.id)
    assert_empty @security.reload.tags
  end

  # A security tag is a family-scoped ANNOTATION, not a change to the holding --
  # the same shape as a transaction's tags, which `TransactionsController#update_tags`
  # gates at `:annotate` so a read_write member can apply them. Gating this at
  # `:write` made the two inconsistent for no stated reason.
  test "a read-write member can tag a holding" do
    member = family_guest
    @holding.account.unshare_with!(member)
    @holding.account.share_with!(member, permission: "read_write")

    sign_in member
    patch tags_holding_path(@holding), params: { security: { tag_ids: [ @tag.id ] } }

    assert_equal [ @tag ], @security.reload.tags.to_a,
                 "a read_write member could not annotate, though they can tag a transaction"
  end

  # The picker must not be offered to someone whose save will be refused: it
  # reads as a working control and fails on submit.
  test "the picker is hidden from a member who cannot annotate" do
    guest = family_guest
    @holding.account.unshare_with!(guest)
    @holding.account.share_with!(guest, permission: "read_only")

    sign_in guest
    get holding_path(@holding)

    assert_response :success
    assert_select "form[action=?]", tags_holding_path(@holding), { count: 0 },
                  "a read-only member was offered a picker whose save is refused"
  end

  test "a read-only member cannot tag a holding" do
    guest = family_guest
    @holding.account.unshare_with!(guest)
    @holding.account.share_with!(guest, permission: "read_only")

    sign_in guest
    patch tags_holding_path(@holding), params: { security: { tag_ids: [ @tag.id ] } }

    assert_equal :read_only, @holding.account.reload.permission_for(guest),
                 "the guest could not reach the holding, so the permission gate was never tested"
    assert_empty @security.reload.tags
    assert_equal I18n.t("accounts.not_authorized"), flash[:alert]
  end

  test "a holding belonging to another family is not reachable" do
    sign_in users(:josh)

    patch tags_holding_path(@holding), params: { security: { tag_ids: [ @other_tag.id ] } }

    assert_response :not_found
    assert_empty @security.reload.tags
  end

  test "the drawer offers the tag picker, with the name the action reads" do
    get holding_path(@holding)

    assert_response :success
    assert_select "form[action=?]", tags_holding_path(@holding), { count: 1 }
    assert_select "form[action=?] [name=?]", tags_holding_path(@holding),
                  "security[tag_ids][]", { minimum: 1 },
                  "the picker does not submit security[tag_ids][], so the action never receives it"
  end

  # Another family's tag names must not be rendered into a page this family sees,
  # for the same reason they must not be attachable.
  #
  # The positive half is what stops this passing vacuously. Asserting only the
  # other family's absence is satisfied by a picker rendering NO tags at all --
  # losing `@family_tags` in `#show` would leave an empty select and every
  # assertion here green (raised by cubic on #201). So this family's tag has to
  # be present in the same breath.
  test "the picker lists this family's tags and only this family's tags" do
    get holding_path(@holding)

    assert_select "form[action=?]", tags_holding_path(@holding) do
      assert_select "*", { text: /#{Regexp.escape(@tag.name)}/, minimum: 1 },
                    "this family's tag is not in the picker, so the other family's absence proves nothing"
      assert_select "*", { text: /#{Regexp.escape(@other_tag.name)}/, count: 0 },
                    "another family's tag name was rendered in the picker"
    end
  end
end
