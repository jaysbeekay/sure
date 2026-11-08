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

  # Data quality is present because the fixture security has no price rows
  # (stale by definition).
  test "renders the hub, the accounts section and data quality" do
    get portfolio_path

    assert_response :success
    assert_select "h1", text: I18n.t("portfolios.show.title")
    assert_equal %w[accounts data_quality], css_select("[data-section-key]").map { |node| node["data-section-key"] }
    assert_select "header + div[role=list]"
  end

  # No section reads the period yet, so the page offers no control that
  # would change nothing.
  test "the page carries no period picker" do
    get portfolio_path(period: "last_5_years")

    assert_response :success
    assert_select "button[aria-label=?]", I18n.t("UI.period_picker.aria_label", period: "5Y"), count: 0
    assert_select "a[href^=?]", "#{portfolio_path}?period=", count: 0
  end

  test "an unknown period falls back rather than erroring" do
    get portfolio_path(period: "not_a_period")

    assert_response :success
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

  # `kpis` is a key not in Portfolio::SectionRegistry::KEYS, and is dropped
  # like any other unknown key.
  test "drops section keys the registry does not know, in both shapes" do
    patch update_preferences_portfolio_path,
      params: { preferences: { portfolio_section_order: %w[kpis nonsense accounts], portfolio_collapsed_sections: { accounts: true, kpis: true, nonsense: true } } },
      as: :json

    assert_response :ok
    @user.reload
    assert_equal %w[accounts], @user.preferences["portfolio_section_order"]
    assert_equal({ "accounts" => true }, @user.preferences["portfolio_collapsed_sections"],
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

  test "data quality rows name the account, open the drawer, and date a stale price" do
    holding = add_unpriced_holding("NOPX")
    dated = Security.create!(ticker: "OLDP", name: "Old price")
    Holding.create!(account: accounts(:investment), security: dated, date: Date.current, qty: 1, price: 10, amount: 10, currency: "USD", cost_basis: 8, cost_basis_locked: true)
    priced_on = 20.days.ago.to_date
    Security::Price.create!(security: dated, date: priced_on, price: 10, currency: "USD")

    get portfolio_path
    assert_response :success

    assert_select "[data-portfolio-issue-kind='missing_cost_basis'] li", text: /NOPX.*#{Regexp.escape(accounts(:investment).name)}/m
    assert_select "[data-portfolio-issue-kind='missing_cost_basis'] a[href=?][data-turbo-frame=drawer]", holding_path(holding)
    assert_select "[data-portfolio-issue-kind='stale_price'] li",
      text: /OLDP.*#{Regexp.escape(I18n.t("portfolios.data_quality.last_priced", date: I18n.l(priced_on, format: :long)))}/m
  end

  # Not stubbed: with nothing held there is nothing to check, so the section
  # goes while the accounts section, read from the same accounts, stays.
  test "data quality is absent when nothing held needs checking" do
    get portfolio_path
    assert_response :success
    assert_select "[data-section-key='data_quality']", count: 1

    Holding.where(account_id: @family.accounts.select(:id)).delete_all

    get portfolio_path
    assert_response :success
    assert_select "[data-section-key='accounts']", count: 1
    assert_select "[data-section-key='data_quality']", count: 0
    assert_select "#portfolio-data-quality", count: 0
  end

  # Each row reads its holding's account and security, which the statement
  # preloads, and the writable accounts are one query for the whole list.
  test "data quality rows add no query per holding" do
    add_unpriced_holding("NOPA")
    one = capture_sql_queries { get portfolio_path }.size

    add_unpriced_holding("NOPB")
    add_unpriced_holding("NOPC")
    three = capture_sql_queries { get portfolio_path }.size

    assert_response :success
    assert_select "[data-portfolio-issue-kind='missing_cost_basis'] li", minimum: 3
    assert_equal one, three, "rendering the data quality rows grew with the number of holdings"
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

    def add_unpriced_holding(ticker)
      security = Security.create!(ticker: ticker, name: "Unpriced #{ticker}")
      Holding.create!(account: accounts(:investment), security: security, date: Date.current, qty: 1, price: 10, amount: 10, currency: "USD")
    end

    def provider_queries(&block)
      capture_sql_queries(&block).count { |sql| sql.include?(%(FROM "lunchflow_accounts")) }
    end
end
