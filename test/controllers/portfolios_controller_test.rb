require "test_helper"

class PortfoliosControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @family = @user.family
    enable_preview(@user)
    sign_in @user
    ensure_tailwind_build
  end

  test "redirects users without preview access to the dashboard" do
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => false))

    get portfolio_path

    assert_redirected_to root_path
    assert_equal I18n.t("preview.not_enabled"), flash[:alert]
  end

  test "renders the hub, its turbo frame and only the sections that have partials" do
    get portfolio_path

    assert_response :success
    assert_select "h1", text: I18n.t("portfolios.show.title")
    assert_select "turbo-frame#portfolio_sections"

    assert_select "[data-section-key=?]", "kpis"
    assert_select "[data-section-key=?]", "value_chart"

    %w[holdings accounts allocation data_quality].each do |key|
      assert_select "[data-section-key=?]", key, count: 0, message: "#{key} has no partial yet"
    end
  end

  test "the period picker reflects the requested period" do
    get portfolio_path(period: "last_5_years")

    assert_response :success
    # DS::MenuItem marks the current row with role=menuitemradio + aria-checked
    # (not aria-current), so that is what the picker's selection looks like.
    assert_select "a[href=?][aria-checked=?]", portfolio_path(period: "last_5_years"), "true"
    assert_select "button[aria-label=?]", I18n.t("UI.period_picker.aria_label", period: "5Y")
    assert_equal "last_5_years", @user.reload.default_period
  end

  test "an unknown period falls back rather than erroring" do
    get portfolio_path(period: "not_a_period")

    assert_response :success
    assert_select "button[aria-label=?]", I18n.t("UI.period_picker.aria_label", period: "30D")
  end

  test "shows an empty state with an add-account link when the family has no investment accounts" do
    user = users(:empty)
    enable_preview(user)
    sign_in user

    get portfolio_path

    assert_response :success
    assert_match I18n.t("portfolios.empty_state.title"), response.body
    assert_select "a[href=?]", new_account_path
    assert_select "turbo-frame#portfolio_sections", count: 0
  end

  test "the KPI row prints the statement's own figures" do
    period = Period.last_30_days
    statement = InvestmentStatement.new(@family, user: @user)
    helpers = ApplicationController.helpers

    expected = [
      helpers.format_money(statement.portfolio_value_money),
      helpers.format_money(statement.net_contributions(period: period)),
      helpers.format_money(statement.totals(period: period).total_income)
    ]
    expected << helpers.format_money(statement.day_change.value) if statement.day_change
    expected << helpers.format_money(statement.unrealized_gains_trend.value) if statement.unrealized_gains_trend
    expected << helpers.format_money(statement.period_return_trend(period: period).value) if statement.period_return_trend(period: period)

    get portfolio_path(period: "last_30_days")

    assert_response :success
    expected.each do |amount|
      assert_match amount, response.body, "the KPI row should print #{amount}"
    end
  end

  test "the value chart is mounted with the statement's series" do
    seed_investment_balances

    period = Period.last_30_days
    series = InvestmentStatement.new(@family, user: @user).value_series(period: period)
    assert_operator series.values.size, :>=, 2, "fixture setup should produce a chartable series"

    get portfolio_path(period: "last_30_days")

    assert_response :success
    chart = css_select("#portfolioValueChart").first
    assert chart, "the value chart should be mounted"
    data = JSON.parse(chart["data-time-series-chart-data-value"])
    assert_equal series.values.size, data["values"].size
  end

  test "saves the section order and collapsed set under the portfolio namespace only" do
    patch update_preferences_portfolio_path,
      params: { preferences: { portfolio_section_order: %w[value_chart kpis], portfolio_collapsed_sections: { kpis: true } } },
      as: :json

    assert_response :ok
    @user.reload
    assert_equal %w[value_chart kpis], @user.section_order("portfolio")
    assert @user.section_collapsed?("portfolio", "kpis")
    assert_nil @user.preferences["reports_section_order"]
  end

  test "drops preference keys that are not the portfolio's own" do
    patch update_preferences_portfolio_path,
      params: { preferences: { reports_section_order: %w[x] } },
      as: :json

    assert_response :ok
    assert_nil @user.reload.preferences["reports_section_order"]
  end

  test "renders sections in the saved order, collapsed where the user left them" do
    @user.update_section_preferences("portfolio", order: %w[value_chart kpis], collapsed: { "kpis" => true })

    get portfolio_path

    assert_response :success
    assert_equal %w[value_chart kpis], css_select("[data-section-key]").map { |node| node["data-section-key"] }
    assert_select "[data-section-key=kpis][data-reports-section-collapsed-value=?]", "true"
    assert_select "[data-section-key=value_chart][data-reports-section-collapsed-value=?]", "false"
  end

  test "the sortable container posts to the portfolio endpoint under its own namespace" do
    get portfolio_path

    assert_response :success
    assert_select "[data-controller~=reports-sortable][data-reports-sortable-url-value=?][data-reports-sortable-preference-key-value=?]",
                  update_preferences_portfolio_path, "portfolio"
    assert_select "[data-section-key=kpis][data-reports-section-url-value=?][data-reports-section-preference-key-value=?]",
                  update_preferences_portfolio_path, "portfolio"
  end

  test "the nav shows Portfolio on desktop only, and never without the preview flag" do
    get portfolio_path

    assert_response :success
    assert_select "ul li a[href=?]", portfolio_path, minimum: 1
    assert_select "nav[data-viewport-target=bottomNav] a[href=?]", portfolio_path, count: 0

    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => false))
    get root_path

    assert_response :success
    assert_select "a[href=?]", portfolio_path, count: 0
  end

  private
    def enable_preview(user)
      user.update!(preferences: (user.preferences || {}).merge("preview_features_enabled" => true))
    end

    # The investment fixtures carry holdings but no balance history, and a
    # chart needs at least two points.
    def seed_investment_balances
      account = accounts(:investment)
      (0..10).each do |days_ago|
        date = days_ago.days.ago.to_date
        account.balances.create!(date: date, balance: 10_000 + days_ago, cash_balance: 5_000, currency: "USD")
      end
    end
end
