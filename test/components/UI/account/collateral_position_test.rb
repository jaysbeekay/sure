require "test_helper"

class UI::Account::CollateralPositionTest < ViewComponent::TestCase
  setup do
    @admin = users(:family_admin)
    @member = users(:family_member)
    @property = accounts(:property)
    @loan_account = accounts(:loan)
    @property.update_columns(balance: 550_000)
    @loan_account.update_columns(balance: 500_000)
    @loan_account.loan.update!(collateral_account: @property)
  end

  test "an asset shows value, debt and equity, and links the loans" do
    render_inline UI::Account::CollateralPosition.new(account: @property, viewer: @admin)

    assert_selector "h3", text: "Secures"
    assert_selector "h4", text: "Value"
    assert_selector "h4", text: "Debt secured"
    assert_selector "h4", text: "Equity"
    assert_selector "p", text: "$550,000.00"
    assert_selector "p", text: "$500,000.00"
    assert_selector "p", text: "$50,000.00"
    assert_link @loan_account.name
    assert_no_text "Equity is not shown"
  end

  test "a loan shows the asset that secures it" do
    render_inline UI::Account::CollateralPosition.new(account: @loan_account, viewer: @admin)

    assert_selector "h3", text: "Secured by"
    assert_link @property.name
    assert_selector "p", text: "$50,000.00"
  end

  test "equity and debt are withheld, with a note, when the viewer cannot see every loan" do
    second = @loan_account.family.accounts.create!(
      name: "Hidden second mortgage", currency: "USD", balance: 100_000, owner: @admin, accountable: Loan.new
    )
    second.loan.update!(collateral_account: @property)
    @property.share_with!(@member, permission: "read_only")
    @loan_account.share_with!(@member, permission: "read_only")

    render_inline UI::Account::CollateralPosition.new(account: @property, viewer: @member)

    assert_selector "h4", text: "Value"
    assert_no_selector "h4", text: "Equity"
    assert_no_selector "h4", text: "Debt secured"
    assert_no_text "$400,000.00"
    assert_text "Equity is not shown"
    assert_link @loan_account.name
    assert_no_link second.name
  end

  test "renders nothing for an asset that secures no loan" do
    component = UI::Account::CollateralPosition.new(account: accounts(:vehicle), viewer: @admin)

    render_inline component

    assert_not component.render?
    assert_no_selector "[data-collateral-position]"
  end

  test "renders nothing on a loan whose asset the viewer cannot see" do
    @loan_account.share_with!(@member, permission: "read_only")

    component = UI::Account::CollateralPosition.new(account: @loan_account, viewer: @member)
    render_inline component

    assert_not component.render?
  end
end
