require "test_helper"

class PortfoliosControllerTest < ActionDispatch::IntegrationTest
  include SqlQueryCapture

  setup do
    @user = users(:family_admin)
    @family = @user.family
    enable_preview(@user)
    sign_in @user
    ensure_tailwind_build
  end

  test "redirects users without preview access to the dashboard" do
    disable_preview(@user)

    get portfolio_path

    assert_redirected_to root_path
    assert_equal I18n.t("preview.not_enabled"), flash[:alert]
  end

  # The class-level gate covers every action, so the one endpoint that writes
  # cannot save preferences for a page its caller is not allowed to see.
  test "preference writes are preview-gated like the page" do
    disable_preview(@user)

    patch update_preferences_portfolio_path,
      params: { preferences: { portfolio_section_order: %w[accounts] } },
      as: :json

    assert_redirected_to root_path
    assert_nil @user.reload.preferences["portfolio_section_order"]
  end

  test "a request the gate turns away does not save its period as the user's default" do
    disable_preview(@user)
    @user.update!(default_period: "last_30_days")

    get portfolio_path(period: "last_5_years")

    assert_redirected_to root_path
    assert_equal "last_30_days", @user.reload.default_period
  end

  test "a preview user's period pick is still saved as their default" do
    @user.update!(default_period: "last_30_days")

    get portfolio_path(period: "last_365_days")

    assert_response :success
    assert_equal "last_365_days", @user.reload.default_period
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
    assert_equal %w[kpis performance value_chart accounts], css_select("[data-section-key]").map { |node| node["data-section-key"] }
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

  # The picker shares the heading's row rather than taking one of its own
  # between the heading and the first section, and that row is the frame's
  # first child so the first section follows it.
  test "the period picker shares the heading's row, directly above the sections" do
    get portfolio_path(period: "last_5_years")

    assert_response :success
    assert_select "turbo-frame#portfolio_sections > div:first-child > header h1",
      text: I18n.t("portfolios.show.title")
    assert_select "turbo-frame#portfolio_sections > div:first-child > header + div[data-controller='DS--menu']" do
      assert_select "button[aria-label=?]", I18n.t("UI.period_picker.aria_label", period: "5Y")
    end
    assert_select "turbo-frame#portfolio_sections > div:first-child + div[role=list]"
  end

  # Each picker link re-renders the frame, and the frame sends every other
  # link inside it (an account card, say) to the whole page.
  test "the picker links target the sections frame, and the frame breaks out for everything else" do
    get portfolio_path(period: "last_5_years")

    assert_response :success
    assert_select "turbo-frame#portfolio_sections[target=_top]"
    assert_select "a[href=?][data-turbo-frame=?]", portfolio_path(period: "last_30_days"), "portfolio_sections"
  end

  test "an unknown period falls back rather than erroring" do
    get portfolio_path(period: "not_a_period")

    assert_response :success
    assert_select "button[aria-label=?]", I18n.t("UI.period_picker.aria_label", period: "30D")
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

  # An account whose currency has no rate is left out of the period return
  # rather than converted at parity, and the card has to say so: a partial
  # figure that does not announce itself reads as a whole one.
  test "the period return card says how many accounts it left out" do
    hint = I18n.t("portfolios.kpi_row.period_return_unconvertible", count: 2)

    get portfolio_path(period: "last_30_days")
    assert_response :success
    assert_no_match hint, response.body, "the fixture must convert every account, or this proves nothing"

    InvestmentStatement.any_instance.stubs(:period_return_unconvertible_count).returns(2)
    get portfolio_path(period: "last_30_days")

    assert_response :success
    assert_select "[data-section-key=kpis] p", text: "#{Period.last_30_days.comparison_label} · #{hint}"
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

  # The chart reads the picked period, not the default one.
  test "the value chart follows the picked period" do
    seed_investment_balances

    get portfolio_path(period: "last_7_days")
    week = JSON.parse(css_select("#portfolioValueChart").first["data-time-series-chart-data-value"])["values"].size
    get portfolio_path(period: "last_30_days")
    month = JSON.parse(css_select("#portfolioValueChart").first["data-time-series-chart-data-value"])["values"].size

    assert_equal InvestmentStatement.new(@family, user: @user).value_series(period: Period.last_7_days).values.size, week
    assert_operator week, :<, month
  end

  # A return is a rate, not an amount. The card takes `money:` and `trend:` as
  # well, and both format with a currency symbol, so the failure this guards
  # against is a 21% return rendering as $0.21 -- plausible-looking, and wrong
  # by two orders of magnitude and a unit.
  test "a return renders as a percentage, not as money" do
    Portfolio::Performance.any_instance.stubs(:time_weighted_return).returns(BigDecimal("0.2134"))
    Portfolio::Performance.any_instance.stubs(:rate_missing?).returns(false)
    Portfolio::Performance.any_instance.stubs(:suppressed_dates).returns([])

    get portfolio_path

    assert_response :success
    assert_select "#portfolio-performance" do
      assert_select "p", text: /21\.34%/
    end
    assert_no_match(/\$0\.21/, response.body, "a rate must not be formatted as currency")
  end

  # The money-weighted return is solved per unit of the PERIOD'S SPAN, not as a
  # holding-period figure. Capital that arrives part-way through is therefore
  # expressed over the whole period: money invested for half of a ten-day
  # period and gaining 10% reports about 21% (1.1 ** (10/5) - 1), where TWR
  # reports 10%.
  #
  # The UI must not label that a holding-period return. This
  # is the card copy most likely to produce a "my broker says something
  # different" report, so the wording is pinned rather than left to drift, in
  # both locales -- a German reader gets the same warning or none at all.
  test "the money-weighted card says it is a period figure, in every locale" do
    Portfolio::Performance.any_instance.stubs(:money_weighted_return).returns(BigDecimal("0.21"))
    Portfolio::Performance.any_instance.stubs(:rate_missing?).returns(false)
    Portfolio::Performance.any_instance.stubs(:suppressed_dates).returns([])

    get portfolio_path

    assert_response :success
    # A fragment, not the whole hint: it carries an apostrophe and an em dash,
    # which render HTML-escaped and would never match the raw string.
    assert_match(/Money-weighted, over the period/, response.body)

    %i[en de].each do |locale|
      label = I18n.t("portfolios.performance.mwr", locale: locale)
      hint = I18n.t("portfolios.performance.mwr_hint", locale: locale)

      assert_match(/period|Zeitraum/i, label,
                   "#{locale} label must say the figure is over the period, not a holding-period return")
      assert_match(/when money was invested|wann Geld angelegt wurde/i, hint,
                   "#{locale} hint must say the figure reflects when money was invested")
    end
  end

  # "Left out" is true of the chained TWR and of nothing else on this section. A
  # suppressed day keeps its place in the series: volatility counts it as an
  # observation of zero, and its flows stay in the money-weighted series. Three
  # of the six figures on the card are computed from a day the banner told the
  # reader was omitted, so the wording is pinned in both locales rather than left
  # to drift back.
  test "the suppressed-days banner says a day was counted as zero, in every locale" do
    Portfolio::Performance.any_instance.stubs(:rate_missing?).returns(false)
    Portfolio::Performance.any_instance.stubs(:suppressed_dates).returns([ Date.current ])

    get portfolio_path
    assert_response :success

    assert_match(/counted as a zero return/, response.body)

    %i[en de].each do |locale|
      %i[one other].each do |count|
        line = I18n.t("portfolios.performance.suppressed_days.#{count}", locale: locale)

        assert_match(/zero return|Nullrendite/i, line,
                     "#{locale}.#{count} must say the day was counted as zero")
        assert_no_match(/left out|ausgelassen/i, line,
                        "#{locale}.#{count} must not say the day was omitted: it is still in the series")
      end
    end
  end

  # Every figure may be withheld: a missing rate, too short a history, or a
  # valuation-only scope. The section still renders and says so, where a
  # vanishing section reads as "this page does not do that".
  test "the performance section states that figures are withheld rather than vanishing" do
    Portfolio::Performance.any_instance.stubs(:time_weighted_return).returns(nil)
    Portfolio::Performance.any_instance.stubs(:annualized_time_weighted_return).returns(nil)
    Portfolio::Performance.any_instance.stubs(:money_weighted_return).returns(nil)
    Portfolio::Performance.any_instance.stubs(:annualized_money_weighted_return).returns(nil)
    Portfolio::Performance.any_instance.stubs(:volatility).returns(nil)
    Portfolio::Performance.any_instance.stubs(:max_drawdown).returns(nil)
    Portfolio::Performance.any_instance.stubs(:rate_missing?).returns(true)
    Portfolio::Performance.any_instance.stubs(:suppressed_dates).returns([])

    get portfolio_path

    assert_response :success
    assert_select "[data-section-key=?]", "performance", count: 1
    assert_match I18n.t("portfolios.performance.rate_missing"), response.body
    assert_match I18n.t("portfolios.kpi_row.no_data"), response.body
  end

  # Six cards of the same shape, each a rate: distinct figures per card, so a
  # card that printed its neighbour's would show.
  test "each return card prints its own figure" do
    {
      time_weighted_return: "0.1", annualized_time_weighted_return: "0.2", money_weighted_return: "0.3",
      annualized_money_weighted_return: "0.4", volatility: "0.05", max_drawdown: "0.06"
    }.each { |method, rate| Portfolio::Performance.any_instance.stubs(method).returns(BigDecimal(rate)) }
    Portfolio::Performance.any_instance.stubs(:rate_missing?).returns(false)
    Portfolio::Performance.any_instance.stubs(:suppressed_dates).returns([])

    get portfolio_path

    assert_response :success
    cards = css_select("#portfolio-performance .grid > div").to_h do |card|
      [ card.at_css("span").text.strip, card.at_css("p").text.strip ]
    end
    expected = { twr: "10.00%", annualized_twr: "20.00%", mwr: "30.00%", annualized_mwr: "40.00%",
                 volatility: "5.00%", max_drawdown: "6.00%" }
    assert_equal expected.transform_keys { |key| I18n.t("portfolios.performance.#{key}") }, cards
  end

  # The index chart is mounted with the levels the registry built, and only
  # when there is a line to draw.
  test "the index chart is mounted with the rebased levels" do
    Portfolio::Performance.any_instance.stubs(:index_series).returns([
      [ 2.days.ago.to_date, BigDecimal("100") ],
      [ 1.day.ago.to_date, BigDecimal("104.5") ],
      [ Date.current, BigDecimal("102.25") ]
    ])

    get portfolio_path

    assert_response :success
    chart = css_select("#portfolioIndexChart").first
    assert chart, "the index chart should be mounted"
    values = JSON.parse(chart["data-time-series-chart-data-value"])["values"]
    assert_equal [ "100.0", "104.5", "102.25" ], values.map { |v| v["value"].to_s }
  end

  test "the index chart section is absent when there is no line to draw" do
    Portfolio::Performance.any_instance.stubs(:index_series).returns([ [ Date.current, BigDecimal("100") ] ])

    get portfolio_path

    assert_response :success
    assert_select "[data-section-key=?]", "index_chart", count: 0
    assert_select "#portfolioIndexChart", count: 0
  end

  test "renders sections in the saved order, collapsed where the user left them" do
    @user.update_section_preferences("portfolio", order: %w[value_chart kpis], collapsed: { "kpis" => true })

    get portfolio_path

    assert_response :success
    # The saved order places the chart first; sections it does not mention
    # follow in declaration order. `index_chart` is absent on purpose: no
    # account holds a balance on two days of the period, so there is no
    # time-weighted return to draw, rather than a flat line of 100s chained
    # from calendar rows of zeros.
    assert_equal %w[value_chart kpis performance accounts], css_select("[data-section-key]").map { |node| node["data-section-key"] }
    assert_select "[data-section-key=kpis][data-reports-section-collapsed-value=?]", "true"
    assert_select "[data-section-key=value_chart][data-reports-section-collapsed-value=?]", "false"
  end

  test "shows an empty state with an add-account link when the family has no investment accounts" do
    user = users(:empty)
    enable_preview(user)
    sign_in user
    assert_empty InvestmentStatement.new(user.family, user: user).investment_accounts

    get portfolio_path

    assert_response :success
    assert_match I18n.t("portfolios.empty_state.title"), response.body
    assert_select "a[href=?]", new_account_path
    assert_select "[data-section-key]", count: 0
    assert_select "turbo-frame#portfolio_sections", count: 0
  end

  test "saves the section order and collapsed set under the portfolio namespace only" do
    patch update_preferences_portfolio_path,
      params: { preferences: { portfolio_section_order: %w[accounts], portfolio_collapsed_sections: { accounts: true } } },
      as: :json

    assert_response :ok
    @user.reload
    assert_equal %w[accounts], @user.preferences["portfolio_section_order"]
    assert @user.section_collapsed?("portfolio", "accounts")
    assert_nil @user.preferences["reports_section_order"]
    assert_nil @user.preferences["reports_collapsed_sections"]
  end

  test "drops preference keys that are not the portfolio's own" do
    patch update_preferences_portfolio_path,
      params: { preferences: { reports_section_order: %w[x] } },
      as: :json

    assert_response :ok
    assert_nil @user.reload.preferences["reports_section_order"]
  end

  # `drivers` is a key not in Portfolio::SectionRegistry::KEYS, and is
  # dropped like any other unknown key.
  test "drops section keys the registry does not know, in both shapes" do
    patch update_preferences_portfolio_path,
      params: { preferences: { portfolio_section_order: %w[kpis drivers nonsense value_chart accounts], portfolio_collapsed_sections: { kpis: true, drivers: true, nonsense: true } } },
      as: :json

    assert_response :ok
    @user.reload
    assert_equal %w[kpis value_chart accounts], @user.preferences["portfolio_section_order"]
    assert_equal({ "kpis" => true }, @user.preferences["portfolio_collapsed_sections"],
      "an unknown key must not be written into the user's preferences")
  end

  test "a preferences body that is not an object is refused and writes nothing" do
    before = @user.reload.preferences.dup

    patch update_preferences_portfolio_path, params: { preferences: "foo" }

    assert_response :bad_request
    assert_equal before, @user.reload.preferences
  end

  test "deduplicates the saved order, first occurrence winning" do
    patch update_preferences_portfolio_path,
      params: { preferences: { portfolio_section_order: %w[accounts accounts] } },
      as: :json

    assert_response :ok
    assert_equal %w[accounts], @user.reload.preferences["portfolio_section_order"]
  end

  test "a collapsed payload that is not an object is dropped rather than raised on" do
    patch update_preferences_portfolio_path,
      params: { preferences: { portfolio_collapsed_sections: "true", portfolio_section_order: %w[accounts] } },
      as: :json

    assert_response :ok
    @user.reload
    assert_nil @user.preferences["portfolio_collapsed_sections"]
    assert_equal %w[accounts], @user.preferences["portfolio_section_order"]
  end

  test "renders sections collapsed where the user left them" do
    get portfolio_path
    assert_select "[data-section-key=accounts][data-reports-section-collapsed-value=?]", "false"
    assert_select "[data-section-key=accounts] > details[open] > summary"

    @user.update_section_preferences("portfolio", collapsed: { "accounts" => true })
    get portfolio_path

    assert_response :success
    assert_select "[data-section-key=accounts][data-reports-section-collapsed-value=?]", "true"
    assert_select "[data-section-key=accounts] > details:not([open]) > summary"
  end

  test "the sortable container posts to the portfolio endpoint under its own namespace" do
    get portfolio_path

    assert_response :success
    assert_select "[data-controller~=sortable-list][data-sortable-list-url-value=?][data-sortable-list-param-value=?]",
                  update_preferences_portfolio_path, "preferences.portfolio_section_order"
    assert_select "[data-section-key=accounts][data-reports-section-url-value=?][data-reports-section-preference-key-value=?]",
                  update_preferences_portfolio_path, "portfolio"
  end

  test "the nav shows Portfolio on desktop only, and never without the preview flag" do
    get portfolio_path

    assert_response :success
    assert_select "ul li a[href=?]", portfolio_path, minimum: 1
    assert_select "nav[data-viewport-target=bottomNav] a[href=?]", portfolio_path, count: 0

    disable_preview(@user)
    get root_path

    assert_response :success
    assert_select "a[href=?]", portfolio_path, count: 0
  end

  # Portfolio is the only desktop-only entry, so every other item still
  # reaches both bars: the mobile bar is the desktop rail without Portfolio,
  # plus the mobile-only Assistant.
  test "every other nav item still renders in both bars" do
    get root_path
    assert_response :success

    desktop = css_select("ul li a").map { |link| link["href"] }
    mobile = css_select("nav[data-viewport-target=bottomNav] a").map { |link| link["href"] }

    assert_includes desktop, portfolio_path
    assert_equal desktop - [ portfolio_path ], mobile - [ chats_path ]
    assert_includes mobile, chats_path if @family.assistant_enabled?
  end

  test "accounts grid links every countable investment account to its holdings tab and skips excluded shares" do
    other = users(:family_member)
    shared = @family.accounts.create!(name: "Shared brokerage", balance: 500, currency: "USD", accountable: Investment.new, owner: other)
    shared.share_with!(@user, permission: "read_only", include_in_finances: false)

    get portfolio_path
    assert_response :success

    assert_select "#portfolio-accounts a[href=?]", account_path(accounts(:investment), tab: "holdings")
    assert_select "#portfolio-accounts a[href=?]", account_path(shared, tab: "holdings"), count: 0
    assert_equal InvestmentStatement.new(@family, user: @user).investment_accounts.count, css_select("#portfolio-accounts a").size
    # The cards sit in a narrow grid cell, so they truncate and show focus.
    assert_select "#portfolio-accounts a.focus-ring p.truncate", minimum: 2
  end

  # Each card's logo falls back to its provider's, read through
  # AccountProvider#provider, so the provider records are loaded with the
  # accounts rather than once per card.
  test "the accounts grid loads provider-linked accounts without a query per card" do
    link_investment_account(0)
    one = provider_queries { get portfolio_path }

    link_investment_account(1)
    link_investment_account(2)
    three = provider_queries { get portfolio_path }

    assert_response :success
    assert_select "#portfolio-accounts a", minimum: 3
    assert_equal one, three, "loading the linked accounts' providers grew with the number of cards"
  end

  private
    def enable_preview(user)
      user.update!(preferences: (user.preferences || {}).merge("preview_features_enabled" => true))
    end

    def disable_preview(user)
      user.update!(preferences: (user.preferences || {}).merge("preview_features_enabled" => false))
    end

    def link_investment_account(index)
      account = @family.accounts.create!(name: "Linked brokerage #{index}", balance: 1_000, currency: "USD",
                                         accountable: Investment.new, owner: @user)
      provider = LunchflowAccount.create!(lunchflow_item: lunchflow_items(:one), account_id: "lf_portfolio_#{index}",
                                          name: account.name, currency: "USD")
      AccountProvider.create!(account: account, provider: provider)
    end

    def provider_queries(&block)
      capture_sql_queries(&block).count { |sql| sql.include?(%(FROM "lunchflow_accounts")) }
    end

    def seed_investment_balances
      account = accounts(:investment)
      (0..10).each do |days_ago|
        date = days_ago.days.ago.to_date
        account.balances.create!(date: date, balance: 10_000 + days_ago, cash_balance: 5_000, currency: "USD")
      end
    end
end
