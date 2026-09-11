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

  # The class-level gate covers every action, so the one endpoint that writes
  # cannot save preferences for a page its caller is not allowed to see.
  test "preference writes are preview-gated like the page" do
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => false))

    patch update_preferences_portfolio_path,
      params: { preferences: { portfolio_section_order: %w[kpis] } },
      as: :json

    assert_redirected_to root_path
    assert_nil @user.reload.preferences["portfolio_section_order"]
  end

  # The KPI row reads the family's income totals. Those used a ::boolean cast
  # on provider pending flags, so one flag PostgreSQL cannot parse raised out
  # of the aggregation and took the whole page down with it.
  test "the hub renders when an income entry carries a non-boolean pending flag" do
    accounts(:investment).entries.create!(
      name: "Dividend", date: Date.current, amount: -12, currency: "USD",
      entryable: Transaction.new(investment_activity_label: "Dividend", extra: { "plaid" => { "pending" => "maybe" } })
    )

    get portfolio_path

    assert_response :success
    assert_select "[data-section-key=?]", "kpis", count: 1
  end

  test "renders the hub, its turbo frame and every section the family has data for" do
    get portfolio_path

    assert_response :success
    assert_select "h1", text: I18n.t("portfolios.show.title")
    assert_select "turbo-frame#portfolio_sections"

    # The fixture family holds AAPL in accounts(:investment), so every
    # section has something to show; data quality is present because the
    # fixture security has no price rows (stale by definition).
    %w[kpis value_chart holdings accounts allocation data_quality].each do |key|
      assert_select "[data-section-key=?]", key, count: 1
    end
  end

  test "sort and grouping params are whitelisted before they reach the picker links" do
    get portfolio_path(sort: "name", dir: "asc", by: "kind")
    assert_response :success
    assert_select "a[href=?]", "#{portfolio_path}?by=kind&dir=asc&period=last_5_years&sort=name"

    get portfolio_path(sort: "drop table", dir: "sideways", by: "nonsense")
    assert_response :success
    assert_select "a[href=?]", "#{portfolio_path}?period=last_5_years"
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

  test "a collapsed payload that is not an object is dropped rather than raised on" do
    patch update_preferences_portfolio_path,
      params: { preferences: { portfolio_collapsed_sections: "true", portfolio_section_order: %w[kpis] } },
      as: :json

    assert_response :ok
    @user.reload
    assert_nil @user.preferences["portfolio_collapsed_sections"]
    assert_equal %w[kpis], @user.section_order("portfolio")
  end

  test "a saved order with repeated keys renders each section once" do
    patch update_preferences_portfolio_path,
      params: { preferences: { portfolio_section_order: %w[value_chart kpis value_chart kpis] } },
      as: :json

    assert_response :ok
    assert_equal %w[value_chart kpis], @user.reload.section_order("portfolio")

    get portfolio_path
    assert_response :success
    keys = css_select("[data-section-key]").map { |node| node["data-section-key"] }
    assert_equal keys.uniq, keys
    assert_equal %w[value_chart kpis], keys.first(2)
  end

  test "renders sections in the saved order, collapsed where the user left them" do
    @user.update_section_preferences("portfolio", order: %w[value_chart kpis], collapsed: { "kpis" => true })

    get portfolio_path

    assert_response :success
    # The saved order places the chart first; sections it does not mention
    # follow in declaration order.
    assert_equal %w[value_chart kpis holdings accounts allocation data_quality],
      css_select("[data-section-key]").map { |node| node["data-section-key"] }
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

  # --- holdings table tests ---

  test "holdings table renders one row per security with its per-account positions" do
    second = create_second_aapl_account(qty: 20, price: 215)
    statement = InvestmentStatement.new(@family, user: @user)
    row = statement.holdings_table_rows.find { |r| r.ticker == "AAPL" }
    assert_equal 2, row.positions.size, "fixture must hold AAPL in two accounts"

    get portfolio_path
    assert_response :success

    assert_select "#portfolio-holdings tr[data-portfolio-holding='AAPL']", count: 1
    assert_select "#portfolio-holdings tr[data-portfolio-holding='AAPL'] td[data-portfolio-value]", text: ApplicationController.helpers.format_money(row.amount_money)
    assert_select "#portfolio-holdings tr[data-portfolio-holding='AAPL'] button[aria-expanded='false'][aria-controls]"
    positions = css_select("#portfolio-holdings [data-portfolio-positions='AAPL'] a[href^='/holdings/']")
    assert_equal 2, positions.size
    assert_includes positions.map { |a| a["href"] }, holding_path(second.holdings.first)
  end

  test "holdings table sorts through whitelisted links that keep the period and grouping" do
    zzz = Security.create!(ticker: "ZZZ", name: "Zeta")
    Holding.create!(account: accounts(:investment), security: zzz, date: Date.current, qty: 1, price: 10, amount: 10, currency: "USD", cost_basis: 8, cost_basis_locked: true)

    get portfolio_path(sort: "name", dir: "asc", by: "kind")
    assert_response :success

    assert_equal %w[AAPL ZZZ], css_select("#portfolio-holdings tr[data-portfolio-holding]").map { |n| n["data-portfolio-holding"] }
    assert_select "#portfolio-holdings th[aria-sort='ascending'] a[href=?]", "#{portfolio_path}?by=kind&dir=desc&period=last_30_days&sort=name"
    assert_select "#portfolio-holdings th a[href=?]", "#{portfolio_path}?by=kind&dir=desc&period=last_30_days&sort=value"
    assert_select "#portfolio-holdings th[aria-sort]", count: 1

    get portfolio_path(sort: "value", dir: "asc")
    assert_equal %w[ZZZ AAPL], css_select("#portfolio-holdings tr[data-portfolio-holding]").map { |n| n["data-portfolio-holding"] }
  end

  test "holdings table flags a row whose position has no cost basis" do
    priced = Security.create!(ticker: "BASIS", name: "With basis")
    Holding.create!(account: accounts(:investment), security: priced, date: Date.current, qty: 1, price: 10, amount: 10, currency: "USD", cost_basis: 8, cost_basis_locked: true)
    # Neither a stored basis nor a buy trade to compute one from, so
    # Holding#avg_cost is nil and the row is flagged. AAPL is deliberately
    # not the example: it has a fixture trade, so its basis is computable
    # even though nothing is stored on the holding.
    unknown = Security.create!(ticker: "NOBASIS", name: "Without basis")
    Holding.create!(account: accounts(:investment), security: unknown, date: Date.current, qty: 1, price: 10, amount: 10, currency: "USD")

    get portfolio_path
    assert_response :success

    assert_select "tr[data-portfolio-holding='NOBASIS']", text: /#{I18n.t("portfolios.holdings.missing_cost_basis")}/
    assert_select "tr[data-portfolio-holding='AAPL']", text: /#{I18n.t("portfolios.holdings.missing_cost_basis")}/, count: 0,
      message: "AAPL's basis is computable from its trade, so the row must not warn"
    assert_select "tr[data-portfolio-holding='BASIS']", text: /#{I18n.t("portfolios.holdings.missing_cost_basis")}/, count: 0
    assert_select "tr[data-portfolio-holding='BASIS']", text: /#{Regexp.escape(ApplicationController.helpers.format_money(Money.new(8, "USD")))}/
  end

  test "the page's query count is bounded and does not grow with holdings" do
    build_portfolio(accounts: 10, securities: 6)
    baseline = capture_sql_queries { get portfolio_path }
    assert_response :success

    # Measured: 54 queries for this page (layout included) at 10 accounts and
    # 60 holdings when this test was written, none of them per holding or per
    # account. The ceiling is that figure plus a little headroom, not a
    # guess; the assertion below is the one that matters.
    assert_operator baseline.size, :<=, PORTFOLIO_QUERY_CEILING, "GET /portfolio issued #{baseline.size} queries"

    build_portfolio(accounts: 10, securities: 2, existing_accounts: @family.accounts.where("name LIKE 'Bulk %'").to_a)
    grown = capture_sql_queries { get portfolio_path }
    assert_response :success

    assert_equal baseline.size, grown.size, "adding 20 holdings changed the query count:\n#{(grown - baseline).join("\n")}"
  end

  # --- accounts, allocation and data quality tests ---

  test "accounts grid links every countable investment account to its holdings tab and skips excluded shares" do
    other = users(:family_member)
    shared = @family.accounts.create!(name: "Shared brokerage", balance: 500, currency: "USD", accountable: Investment.new, owner: other)
    shared.share_with!(@user, permission: "read_only", include_in_finances: false)

    get portfolio_path
    assert_response :success

    assert_select "#portfolio-accounts a[href=?]", account_path(accounts(:investment), tab: "holdings")
    assert_select "#portfolio-accounts a[href=?]", account_path(shared, tab: "holdings"), count: 0
    assert_equal InvestmentStatement.new(@family, user: @user).investment_accounts.count, css_select("#portfolio-accounts a").size
  end

  test "allocation donut carries the grouping's segments and switches grouping through links" do
    statement = InvestmentStatement.new(@family, user: @user)

    get portfolio_path
    assert_response :success
    mount = css_select("#portfolio-allocation [data-controller='donut-chart']").first
    segments = JSON.parse(mount["data-donut-chart-segments-value"])
    assert_equal statement.allocation_by(nil).map(&:id), segments.map { |s| s["id"] }
    assert_in_delta 100.0, segments.sum { |s| s["percentage"] }, 0.2
    assert segments.all? { |s| s["color"].match?(/\A#\h{6}\z/) }

    get portfolio_path(by: "kind", sort: "name", dir: "asc")
    assert_response :success
    assert_select "#portfolio-allocation a[aria-current='true'][href=?]", "#{portfolio_path}?by=kind&dir=asc&period=last_30_days&sort=name"
    assert_select "#portfolio-allocation a[href=?]", "#{portfolio_path}?by=currency&dir=asc&period=last_30_days&sort=name"
    assert_select "#portfolio-allocation [data-portfolio-allocation='kind'] p", text: I18n.t("portfolios.allocation.kinds.standard")
  end

  test "data quality lists the reasons and hides itself when there is nothing to fix" do
    unpriced = Security.create!(ticker: "NOPX", name: "Unpriced")
    offline = Security.create!(ticker: "OFFL", name: "Offline", offline: true)
    holding = Holding.create!(account: accounts(:investment), security: unpriced, date: Date.current, qty: 1, price: 10, amount: 10, currency: "USD")
    Holding.create!(account: accounts(:investment), security: offline, date: Date.current, qty: 1, price: 10, amount: 10, currency: "USD", cost_basis: 8, cost_basis_locked: true)
    Security::Price.create!(security: offline, date: Date.current, price: 10, currency: "USD")

    get portfolio_path
    assert_response :success

    assert_select "[data-portfolio-issue-kind='missing_cost_basis'] a[href=?]", holding_path(holding), text: I18n.t("portfolios.data_quality.set_cost_basis")
    assert_select "[data-portfolio-issue-kind='stale_price'] li", text: /NOPX/
    assert_select "[data-portfolio-issue-kind='stale_price'] li", text: /#{I18n.t("portfolios.data_quality.never_priced")}/
    assert_select "[data-portfolio-issue-kind='provider'] li", text: /OFFL.*#{I18n.t("portfolios.data_quality.provider_statuses.offline")}/m

    InvestmentStatement.any_instance.stubs(:data_quality_issues).returns([])
    get portfolio_path
    assert_response :success
    assert_select "[data-section-key='data_quality']", count: 0
  end

  test "data quality offers the cost-basis drawer only where the user may write" do
    other = users(:family_member)
    shared = @family.accounts.create!(name: "Read-only broker", balance: 500, cash_balance: 0, currency: "USD", accountable: Investment.new, owner: other)
    shared.share_with!(@user, permission: "read_only", include_in_finances: true)
    unpriced = Security.create!(ticker: "NOPX", name: "Unpriced")
    read_only_holding = Holding.create!(account: shared, security: unpriced, date: Date.current, qty: 1, price: 10, amount: 10, currency: "USD")
    own_holding = Holding.create!(account: accounts(:investment), security: unpriced, date: Date.current, qty: 1, price: 10, amount: 10, currency: "USD")

    get portfolio_path
    assert_response :success

    assert_select "[data-portfolio-issue-kind='missing_cost_basis'] a[href=?]", holding_path(own_holding)
    assert_select "[data-portfolio-issue-kind='missing_cost_basis'] a[href=?]", holding_path(read_only_holding), count: 0,
      message: "a read-only share cannot PATCH the holding, so it must not be offered the drawer"
    assert_select "[data-portfolio-issue-kind='missing_cost_basis']", text: /#{I18n.t("portfolios.data_quality.read_only")}/
  end

  PORTFOLIO_QUERY_CEILING = 60 # measured 54, see the ceiling test

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

    def create_second_aapl_account(qty:, price:)
      account = @family.accounts.create!(owner: @user, name: "Second Brokerage", balance: qty * price, cash_balance: 0, currency: "USD", accountable: Investment.new)
      Holding.create!(account: account, security: securities(:aapl), date: Date.current, qty: qty, price: price, amount: qty * price, currency: "USD")
      account
    end

    # `accounts` investment accounts each holding `securities` securities,
    # with a previous-day snapshot per position so day change has work to do.
    # Every other security has no stored cost basis, the shape a synced
    # brokerage produces, so a view that reached for Holding#avg_cost (and
    # its per-holding trades query) would show up in the count.
    def build_portfolio(accounts:, securities:, existing_accounts: nil)
      accounts = existing_accounts || Array.new(accounts) do |i|
        @family.accounts.create!(owner: @user, name: "Bulk #{i}", balance: 1000 * securities, cash_balance: 50, currency: "USD", accountable: Investment.new)
      end
      securities = Array.new(securities) do |i|
        Security.create!(ticker: "B#{SecureRandom.hex(3).upcase}#{i}", name: "Bulk security #{i}")
      end
      accounts.each do |account|
        securities.each_with_index do |security, index|
          basis = index.even? ? { cost_basis: 90, cost_basis_locked: true } : {}
          Holding.create!(account: account, security: security, date: 1.day.ago.to_date, qty: 10, price: 95, amount: 950, currency: "USD", **basis)
          Holding.create!(account: account, security: security, date: Date.current, qty: 10, price: 100, amount: 1000, currency: "USD", **basis)
        end
      end
    end
end
