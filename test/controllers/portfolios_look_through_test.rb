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

  # Constituent ROWS are not the same as a fund look-through can expand.
  # Security#look_through_weights divides by the sum of the non-nil weights and
  # returns {} when that sum is zero, so a fund whose holdings carry no usable
  # weight expands to nothing -- and the toggle was still offered, as a control
  # that visibly does nothing (raised by cubic on #201).
  test "the toggle is not offered for a fund whose constituents carry no usable weight" do
    fund = Security.create!(
      ticker: "WGHTLESS", name: "Weightless ETF", exchange_operating_mic: "XLON",
      country_code: "GB", sector: "Fund wrapper"
    )
    Security.create!(ticker: "MSFT3", exchange_operating_mic: "XNAS", country_code: "US", sector: "Technology")
    Security.create!(ticker: "JNJ3", exchange_operating_mic: "XNAS", country_code: "US", sector: "Healthcare")
    # One of each kind of unusable weight: absent, and present but zero.
    fund.constituents.create!(ticker: "MSFT3", name: "Microsoft", weight: nil)
    fund.constituents.create!(ticker: "JNJ3", name: "J&J", weight: 0)
    @account.holdings.create!(
      security: fund, date: Date.current, qty: 10, price: 100, amount: 1000, currency: "USD"
    )

    assert_empty fund.look_through_weights,
                 "the fixture must expand to nothing, or the toggle is right to be offered"

    get portfolio_path(by: "sector")

    assert_response :success
    assert_select "a", { text: /See through funds/, count: 0 },
                  "a toggle was offered for a fund that expands to nothing"
  end

  # The axes the look-through does not apply to must not offer it: a fund's
  # constituents have no account of their own, and grouping by security with
  # look-through is meaningless because the security IS the fund.
  test "the toggle is not offered on an axis it does not apply to" do
    hold_a_fund

    get portfolio_path(by: "account")

    # `assert_select ... count: 0` passes against a redirect or an error page
    # too, so it proves nothing until the page is known to have rendered
    # (CodeRabbit, #201). The same omission was in two tests below.
    assert_response :success
    assert_select "a", { text: /See through funds/, count: 0 }
  end

  # The wiring assertion. Without `look_through: @look_through` reaching the
  # statement, both requests return the same segments and this fails.
  test "the parameter changes the segments the page renders" do
    hold_a_fund

    get portfolio_path(by: "sector")
    assert_response :success
    assert_includes response.body, "Fund wrapper"

    get portfolio_path(by: "sector", look_through: "1")
    assert_response :success
    assert_includes response.body, "Technology",
                    "the look_through parameter never reached the statement"
    assert_not_includes response.body, "Fund wrapper",
                        "the wrapper survived a look-through the page claims to be showing"
  end

  test "the grouping control keeps the toggle on as the axis changes" do
    hold_a_fund

    get portfolio_path(by: "sector", look_through: "1")

    assert_response :success
    assert_select "a[href*=?]", "look_through=1", { minimum: 1 },
                  "changing axis would silently drop the look-through"
  end

  # The drill-down reads the fund's OWN columns, so with look-through on it
  # contradicted the parent it hangs under: a fund holding shares and bonds
  # showed an `equity` parent at a fraction of the fund and an `etf` child at
  # all of it, while the `fixed_income` parent had no children at all. Two
  # answers for the same money on one screen (CodeRabbit, #201).
  #
  # Asserts the DELTA: the same request without look-through still opens, so
  # this cannot pass by the disclosure having gone missing for another reason.
  test "asset-class rows do not open onto the fund's own columns under look-through" do
    hold_a_mixed_fund

    get portfolio_path(by: "asset_class")
    assert_response :success
    assert_select "details[data-portfolio-segment]", { minimum: 1 },
                  "the asset-class ladder stopped opening at all, so the test below proves nothing"

    get portfolio_path(by: "asset_class", look_through: "1")
    assert_response :success
    assert_select "details[data-portfolio-segment]", { count: 0 },
                  "a looked-through asset class opened onto the fund's own sub-class"
  end

  # `build_segments` drops every zero-VALUE row, so a fund worth nothing can
  # never contribute a segment however well-weighted its constituents are. The
  # eligibility check counted it anyway, and the toggle appeared and did
  # nothing (CodeRabbit, #201).
  #
  # The holding keeps a non-zero QTY on purpose: `current_holdings` already
  # filters `qty: 0`, so zeroing the quantity removes the holding altogether
  # and proves nothing about this fix. A worthless holding -- shares still
  # held, priced at nothing -- is the state that reaches the gate.
  #
  # Asserts the delta: the SAME fund at a positive value still offers it.
  test "a fund whose holding is worth nothing does not offer the toggle" do
    fund = hold_a_fund
    holding = @account.holdings.find_by(security: fund)

    get portfolio_path(by: "sector")
    assert_response :success
    assert_select "a", { text: /See through funds/, minimum: 1 },
                  "the toggle was already absent, so the assertion below proves nothing"

    holding.update!(price: 0, amount: 0)

    get portfolio_path(by: "sector")
    assert_response :success
    assert_select "a", { text: /See through funds/, count: 0 },
                  "a fund worth nothing offered a toggle that can expand nothing"
  end

  private
    # Local copy: the same helper in PortfoliosControllerTest is private to that
    # class, and the portfolio hub is preview-gated, so without it every request
    # here redirects to the dashboard and the assertions never run.
    def enable_preview(user)
      user.update!(preferences: (user.preferences || {}).merge("preview_features_enabled" => true))
    end

    # A fund whose OWN classification disagrees with what it holds, which is
    # the only shape that shows the contradiction: classified equity/etf, but
    # holding half shares and half bonds.
    def hold_a_mixed_fund
      fund = Security.create!(
        ticker: "VBAL", name: "Balanced ETF", exchange_operating_mic: "XLON",
        country_code: "GB", asset_class: "equity", asset_sub_class: "etf"
      )
      Security.create!(
        ticker: "SHR1", exchange_operating_mic: "XNAS", country_code: "US",
        asset_class: "equity", asset_sub_class: "stock"
      )
      Security.create!(
        ticker: "BND1", exchange_operating_mic: "XNAS", country_code: "US",
        asset_class: "fixed_income", asset_sub_class: "bond"
      )
      fund.constituents.create!(ticker: "SHR1", name: "A share", weight: 60)
      fund.constituents.create!(ticker: "BND1", name: "A bond", weight: 40)
      @account.holdings.create!(
        security: fund, date: Date.current, qty: 10, price: 100, amount: 1000, currency: "USD"
      )
      fund
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
