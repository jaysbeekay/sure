require "test_helper"

# Panel placement for issue #298: the sync button and the actions menu must
# render inside the card header row (the disclosure's <summary>), on par with
# the Wise card — not as a sibling row below it.
class CoinSpotItemPanelRenderTest < ActionDispatch::IntegrationTest
  include ActionView::RecordIdentifier

  setup do
    sign_in users(:family_admin)
    @item = coinstpot_items(:one)
  end

  test "admin: sync and menu buttons render in the card header row" do
    get accounts_url
    assert_response :success
    assert_select "##{dom_id(@item)}", count: 1

    # The header row is the disclosure's <summary>; both actions are
    # button_to forms. A regression back to the old markup (buttons in a
    # sibling `mt-2` div outside the summary) fails exactly these two.
    assert_select "##{dom_id(@item)} details > summary form[action=?]", sync_coinspot_item_path(@item), count: 1
    assert_select "##{dom_id(@item)} details > summary form[action=?]", coinstpot_item_path(@item), count: 1

    # No leftover duplicate actions row anywhere else in the card.
    assert_select "##{dom_id(@item)} form[action=?]", sync_coinspot_item_path(@item), count: 1
    assert_select "##{dom_id(@item)} form[action=?]", coinstpot_item_path(@item), count: 1
  end

  test "admin: import accounts menu link sits in the header when accounts are unlinked" do
    coinspot_accounts.create!(
      coinspot_item: @item,
      name: "BTC Wallet",
      account_id: "cs-test-btc",
      account_type: "crypto",
      currency: "BTC"
    )

    get accounts_url
    assert_response :success
    assert_select "##{dom_id(@item)} details > summary a[href=?]", setup_accounts_coinspot_item_path(@item), count: 1
  end

  test "sync button is disabled while the item is syncing" do
    @item.stubs(:syncing?).returns(true)

    get accounts_url
    assert_response :success
    assert_select "##{dom_id(@item)} details > summary form[action=?] button[disabled]", sync_coinspot_item_path(@item), count: 1
  end

  test "non-admin: no sync or menu buttons on the card at all" do
    sign_in users(:family_member)

    get accounts_url
    assert_response :success
    assert_select "##{dom_id(@item)}", count: 1
    assert_select "##{dom_id(@item)} form[action=?]", sync_coinspot_item_path(@item), count: 0
    assert_select "##{dom_id(@item)} form[action=?]", coinstpot_item_path(@item), count: 0
  end
end
