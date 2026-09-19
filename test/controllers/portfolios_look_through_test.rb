require "test_helper"

# The model half is tested in
# test/models/investment_statement/allocation_tags_and_look_through_test.rb.
# This asserts the toggle is actually WIRED: a control that renders but that
# nothing reads is the defect #191 shipped when a select was added without the
# matching permit.
class PortfoliosLookThroughTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    enable_preview(@user)
    sign_in @user
    ensure_tailwind_build
    @account = accounts(:investment)
  end

  test "the toggle is not offered when the portfolio holds no funds" do
    get portfolio_path(by: "sector")

    assert_response :success
    assert_select "a", { text: /See through funds/, count: 0 },
                  "a toggle was offered that could not do anything"
  end

  test "the toggle is offered once the portfolio holds a fund with constituents" do
    hold_a_fund

    get portfolio_path(by: "sector")

    assert_response :success
    assert_select "a", { text: /See through funds/, minimum: 1 }
  end

  # The axes the look-through does not apply to must not offer it: a fund's
  # constituents have no account of their own, and grouping by security with
  # look-through is meaningless because the security IS the fund.
  test "the toggle is not offered on an axis it does not apply to" do
    hold_a_fund

    get portfolio_path(by: "account")

    assert_select "a", { text: /See through funds/, count: 0 }
  end

  # The wiring assertion. Without `look_through: @look_through` reaching the
  # statement, both requests return the same segments and this fails.
  test "the parameter changes the segments the page renders" do
    hold_a_fund

    get portfolio_path(by: "sector")
    assert_includes response.body, "Fund wrapper"

    get portfolio_path(by: "sector", look_through: "1")
    assert_includes response.body, "Technology",
                    "the look_through parameter never reached the statement"
    assert_not_includes response.body, "Fund wrapper",
                        "the wrapper survived a look-through the page claims to be showing"
  end

  test "the grouping control keeps the toggle on as the axis changes" do
    hold_a_fund

    get portfolio_path(by: "sector", look_through: "1")

    assert_select "a[href*=?]", "look_through=1", { minimum: 1 },
                  "changing axis would silently drop the look-through"
  end

  private
    # Local copy: the same helper in PortfoliosControllerTest is private to that
    # class, and the portfolio hub is preview-gated, so without it every request
    # here redirects to the dashboard and the assertions never run.
    def enable_preview(user)
      user.update!(preferences: (user.preferences || {}).merge("preview_features_enabled" => true))
    end

    def hold_a_fund
      fund = Security.create!(
        ticker: "VWRA", name: "World ETF", exchange_operating_mic: "XLON",
        country_code: "GB", sector: "Fund wrapper"
      )
      Security.create!(ticker: "MSFT2", exchange_operating_mic: "XNAS", country_code: "US", sector: "Technology")
      fund.constituents.create!(ticker: "MSFT2", name: "Microsoft", weight: 100)
      @account.holdings.create!(
        security: fund, date: Date.current, qty: 10, price: 100, amount: 1000, currency: "USD"
      )
      fund
    end
end
