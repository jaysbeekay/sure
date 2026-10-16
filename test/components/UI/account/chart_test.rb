require "test_helper"

class UI::Account::ChartTest < ViewComponent::TestCase
  include PortfolioReturnsTestHelper
  setup do
    @account = accounts(:investment)
    @account.holdings.destroy_all
  end

  test "renders positive gains with explicit plus sign" do
    create_holding(cost_basis: 90)

    render_inline(UI::Account::Chart.new(account: @account, view: "gains"))

    assert_text "+$100.00"
  end

  # The all-time period is widened to the account's own history start, which is
  # right for an account that began after the family did. It must not be widened
  # to a start AFTER the period's end: `Period#initialize` validates the range
  # and raises, so the chart 500s rather than drawing anything.
  #
  # Reachable whenever `history_start_date` is in the future -- a scheduled
  # opening anchor, a valuation dated ahead, a provider backfill that lands
  # tomorrow. The fork's `Account#chart_period` guarded this with
  # `start_date > Date.current`; the generalised version adopted from upstream
  # in the A1 sync did not carry the guard, and the 8 tests on `chart_period`
  # kept passing because the component had stopped calling it.
  test "an account whose history starts after the period ends still renders" do
    @account.update!(name: "Future start")
    Account.any_instance.stubs(:history_start_date).returns(Date.current + 30)

    component = UI::Account::Chart.new(account: @account, period: Period.from_key("all_time"), view: "balance")

    period = component.send(:period)

    assert_operator period.start_date, :<=, period.end_date,
                    "a period whose start is after its end cannot be built at all"
  end

  test "does not sign non-gains views" do
    component = UI::Account::Chart.new(account: @account, view: "balance")

    assert_equal @account.balance_money.format, component.view_balance_display
    refute component.view_balance_display.start_with?("+")
  end

  test "negative gains keep plain money formatting" do
    create_holding(cost_basis: 110)

    component = UI::Account::Chart.new(account: @account, view: "gains")

    assert_equal "-$100.00", component.view_balance_display
  end

  test "converted amount is signed like the main indicator for foreign-currency accounts" do
    @account.update!(currency: "EUR")
    create_holding(cost_basis: 90)
    ExchangeRate.create!(date: Date.current, from_currency: "EUR", to_currency: "USD", rate: 1.1)

    component = UI::Account::Chart.new(account: @account, view: "gains")

    assert_equal "+€100.00", component.view_balance_display
    assert_equal "+$110.00", component.converted_balance_display
  end

  test "scopes all_time period to account history_start_date when history postdates family oldest entry date" do
    account_opening = 60.days.ago.to_date
    @account.stubs(:history_start_date).returns(account_opening)

    family_oldest = 5.years.ago.to_date
    all_time_period = Period.new(key: "all_time", start_date: family_oldest, end_date: Date.current)

    component = UI::Account::Chart.new(account: @account, period: all_time_period)

    assert_equal "all_time", component.period.key
    assert_equal account_opening, component.period.start_date
    assert_equal Date.current, component.period.end_date
    assert_equal "1 day", component.period.interval
  end

  test "does not clamp non-all_time periods even if account opening postdates period start" do
    account_opening = 10.days.ago.to_date
    @account.stubs(:history_start_date).returns(account_opening)

    last_30_days = Period.from_key("last_30_days")
    component = UI::Account::Chart.new(account: @account, period: last_30_days)

    assert_equal "last_30_days", component.period.key
    assert_equal 30.days.ago.to_date, component.period.start_date
  end

  test "unlinked account with trade 2 years ago clamps all_time to 2 years with 1 week interval" do
    two_years_ago = 2.years.ago.to_date
    @account.stubs(:history_start_date).returns(two_years_ago)

    family_oldest = 10.years.ago.to_date
    all_time_period = Period.new(key: "all_time", start_date: family_oldest, end_date: Date.current)

    component = UI::Account::Chart.new(account: @account, period: all_time_period)

    assert_equal "all_time", component.period.key
    assert_equal two_years_ago, component.period.start_date
    assert_equal "1 week", component.period.interval
  end

  test "unlinked account with trade 10 years ago clamps all_time to 10 years with 1 month interval" do
    ten_years_ago = 10.years.ago.to_date
    @account.stubs(:history_start_date).returns(ten_years_ago)

    family_oldest = 15.years.ago.to_date
    all_time_period = Period.new(key: "all_time", start_date: family_oldest, end_date: Date.current)

    component = UI::Account::Chart.new(account: @account, period: all_time_period)

    assert_equal "all_time", component.period.key
    assert_equal ten_years_ago, component.period.start_date
    assert_equal "1 month", component.period.interval
  end

  test "unlinked account on 5Y period does not clamp period and shows full timeframe comparison" do
    two_years_ago = 2.years.ago.to_date
    @account.stubs(:history_start_date).returns(two_years_ago)

    last_5_years = Period.from_key("last_5_years")
    component = UI::Account::Chart.new(account: @account, period: last_5_years)

    assert_equal "last_5_years", component.period.key
    assert_equal 5.years.ago.to_date, component.period.start_date
    assert_equal "1 week", component.period.interval

    last_10_years = Period.from_key("last_10_years")
    ten_year_component = UI::Account::Chart.new(account: @account, period: last_10_years)
    assert_equal "last_10_years", ten_year_component.period.key
    assert_equal 10.years.ago.to_date, ten_year_component.period.start_date
    assert_equal "1 month", ten_year_component.period.interval

    # When series covers full period (unlinked account showing 0 baseline)
    mock_series = Series.new(
      start_date: 5.years.ago.to_date,
      end_date: Date.current,
      interval: "1 month",
      values: [
        Series::Value.new(date: 5.years.ago.to_date, date_formatted: "", value: Money.new(0, "USD")),
        Series::Value.new(date: Date.current, date_formatted: "", value: Money.new(100, "USD"))
      ],
      favorable_direction: @account.favorable_direction
    )
    component.stubs(:series).returns(mock_series)
    assert_equal "vs. 5 years ago", component.comparison_label
  end

  test "linked account on 5Y period with trimmed history shows vs available history comparison" do
    two_years_ago = 2.years.ago.to_date
    @account.stubs(:history_start_date).returns(two_years_ago)

    last_5_years = Period.from_key("last_5_years")
    component = UI::Account::Chart.new(account: @account, period: last_5_years)

    # Series normalized to 2 years ago (trimmed from 5 years ago)
    mock_series = Series.new(
      start_date: two_years_ago,
      end_date: Date.current,
      interval: "1 month",
      values: [
        Series::Value.new(date: two_years_ago, date_formatted: "", value: Money.new(0, "USD")),
        Series::Value.new(date: Date.current, date_formatted: "", value: Money.new(100, "USD"))
      ],
      favorable_direction: @account.favorable_direction
    )
    component.stubs(:series).returns(mock_series)
    assert_equal I18n.t("UI.account.chart.vs_available_history"), component.comparison_label
  end

  test "empty account with nil history_start_date leaves all_time period unchanged" do
    @account.stubs(:history_start_date).returns(nil)

    family_oldest = 5.years.ago.to_date
    all_time_period = Period.new(key: "all_time", start_date: family_oldest, end_date: Date.current)

    component = UI::Account::Chart.new(account: @account, period: all_time_period)

    assert_equal "all_time", component.period.key
    assert_equal family_oldest, component.period.start_date
  end

  # #300 stacking: `all_time` from `Period.from_key` is now family-scoped to the
  # earliest Transaction/Trade. The account chart's clamp (which keys off
  # `p.start_date`) must fire the same way when the account's own history begins
  # AFTa that family anchor -- it narrows to the account's own start, not the
  # family's, and the key is preserved. Proves the clamp path still stacks with
  # the new anchor rather than being shadowed by it.
  test "all_time family anchor is clamped to the account's own start when it postdates it" do
    Current.session = Session.create!(user: users(:family_admin))
    family_all_time = Period.from_key("all_time")
    assert_family_anchor(family_all_time)
    # Derived from the anchor rather than fixed, so fixture dates can't decide
    # which side of it the account falls on.
    account_start = family_all_time.start_date + 5.days
    @account.stubs(:history_start_date).returns(account_start)

    component = UI::Account::Chart.new(account: @account, period: family_all_time)

    assert_equal "all_time", component.period.key
    assert_equal account_start, component.period.start_date,
      "the account's own history start must win when it postdates the family anchor"
    assert_equal family_all_time.end_date, component.period.end_date
  ensure
    Current.session = nil
  end

  # #300 stacking (the other side): an account whose history is OLDER than the
  # family anchor is not widened -- the account chart keeps the family-scoped
  # start rather than clamping back to the account's much earlier date.
  test "all_time family anchor is not clamped when the account history predates it" do
    Current.session = Session.create!(user: users(:family_admin))
    family_all_time = Period.from_key("all_time")
    assert_family_anchor(family_all_time)
    account_start = family_all_time.start_date - 1.year
    @account.stubs(:history_start_date).returns(account_start)

    component = UI::Account::Chart.new(account: @account, period: family_all_time)

    assert_equal "all_time", component.period.key
    assert_equal family_all_time.start_date, component.period.start_date,
      "an account whose history predates the family anchor keeps the family start"
  ensure
    Current.session = nil
  end


  # #326. The Total value view of an account that holds trades carries the
  # net contributions line for the chart controller, with each point's
  # difference from total value, and a legend naming both lines.
  test "the total value view of an investment account carries net contributions and a legend" do
    day_one = Date.new(2026, 3, 2)
    account = create_portfolio_account(family: families(:empty))
    lay_balance account: account, date: day_one, opening: 10_000, closing: 10_000
    lay_balance account: account, date: day_one + 1, opening: 10_000, closing: 15_400, cash_flow: 5_000, market_flow: 400
    deposit account: account, date: day_one + 1, amount: 5_000

    render_inline(UI::Account::Chart.new(account: account, period: Period.custom(start_date: day_one, end_date: day_one + 1), view: "balance"))

    comparison = JSON.parse(page.find("#lineChart")["data-time-series-chart-comparison-value"])
    last = comparison["values"].last

    assert_equal "Net contributions", comparison["label"]
    assert_equal [ day_one.iso8601, (day_one + 1).iso8601 ], comparison["values"].map { |v| v["date"] }
    assert_equal "15000.0", last["value"]["amount"]
    assert_equal "400.0", last["difference"]["value"]["amount"]
    assert_equal 2.7, last["difference"]["percent"]
    assert_selector "[data-net-contributions-legend]", text: "Net contributions"
    assert_selector "[data-net-contributions-legend]", text: "Total value"
  end

  test "net contributions are not drawn on the holdings, cash or gains views" do
    %w[holdings_balance cash_balance gains].each do |view|
      component = UI::Account::Chart.new(account: @account, view: view)

      refute component.show_net_contributions?, "#{view} must not carry net contributions"
      render_inline(component)
      refute_selector "[data-time-series-chart-comparison-value]"
      refute_selector "[data-net-contributions-legend]"
    end
  end

  test "net contributions are drawn only for accounts that hold trades" do
    exchange = accounts(:crypto)
    exchange.accountable.update!(subtype: "exchange")
    assert UI::Account::Chart.new(account: exchange, view: "balance").show_net_contributions?

    wallet = accounts(:crypto)
    wallet.accountable.update!(subtype: "wallet")
    refute UI::Account::Chart.new(account: wallet.reload, view: "balance").show_net_contributions?

    depository = accounts(:depository)
    render_inline(UI::Account::Chart.new(account: depository, view: "balance"))
    refute_selector "[data-time-series-chart-comparison-value]"
    refute_selector "[data-net-contributions-legend]"
  end


  test "the chart says when net contributions are understated" do
    @account.stubs(:net_contributions_understated?).returns(true)
    render_inline(UI::Account::Chart.new(account: @account, view: "balance"))
    assert_selector "[data-net-contributions-understated]"

    @account.stubs(:net_contributions_understated?).returns(false)
    render_inline(UI::Account::Chart.new(account: @account, view: "balance"))
    refute_selector "[data-net-contributions-understated]"
  end

  # --- #390: one loan chart at the top of the page --------------------------

  # Test 1. A loan with a schedule takes the loan balance chart, inside the
  # same chart_details frame every account's chart sits in.
  test "an amortizable loan with a chart payload mounts the loan chart and no time-series chart" do
    loan_account = amortizable_loan_account
    payload = Loan::PayoffChart.new(loan_account.loan, as_of: Date.current).payload
    assert_not_nil payload, "the loan must have a schedule, or this test asserts nothing"

    render_inline(UI::Account::Chart.new(account: loan_account, loan_chart: payload))

    assert_selector "turbo-frame##{ActionView::RecordIdentifier.dom_id(loan_account, :chart_details)} [data-controller='loan-payoff-chart']", count: 1
    assert_no_selector "[data-controller='time-series-chart']"
    mounted = JSON.parse(page.find("[data-controller='loan-payoff-chart']")["data-loan-payoff-chart-data-value"])
    assert_equal payload.as_json, mounted
    assert_selector "p.sr-only", text: payload[:aria_description], visible: :all
  end

  # Test 2. Every other account keeps the chart it always had: the time-series
  # mount, every shared period in the picker, and nothing loan-shaped.
  test "a depository account and a loan without a schedule keep the time-series chart" do
    no_schedule = Account.create!(
      family: @account.family, name: "No Rate Loan", balance: 10_000, currency: "USD",
      accountable: Loan.create!(subtype: "other", interest_rate: nil, term_months: 360, rate_type: "fixed")
    )
    assert_nil Loan::PayoffChart.new(no_schedule.loan, as_of: Date.current).payload,
      "a loan with no rate has no schedule to draw"

    # An amount in the request (a stale link, a hand-edited URL) changes
    # nothing for an account with no loan chart to draw it on.
    [ accounts(:depository), no_schedule ].each do |account|
      render_inline(UI::Account::Chart.new(account: account, period: Period.last_30_days, extra_payment_amount: "250"))

      assert_selector "[data-controller='time-series-chart']", count: 1
      assert_no_selector "[data-controller='loan-payoff-chart']"
      assert_no_selector "ul[aria-label='#{I18n.t("UI.account.chart.loan.legend")}']"
      assert_equal Period.all.size, page.all("a[role='menuitemradio']", visible: :all).size,
        "#{account.name}: the picker offers every shared period"
      assert_no_selector "a[href*='extra_payment']", visible: :all
      assert_no_text I18n.t("UI.account.chart.loan.since_start")
    end
  end

  # The legend promises only the lines the payload says are drawn, each in the
  # style its line takes: solid is fact, dashed a forecast, dotted the extra.
  test "the legend lists only the visible series, with the extra line dotted" do
    loan_account = amortizable_loan_account
    extra = loan_account.loan.payoff_projection_with_extra(amount: "250", as_of: Date.current)
    payload = Loan::PayoffChart.new(loan_account.loan, as_of: Date.current, extra_projection: extra).payload
    legend = "ul[aria-label='#{I18n.t("UI.account.chart.loan.legend")}'] li"

    render_inline(UI::Account::Chart.new(account: loan_account, loan_chart: payload.merge(visible: %w[actual scheduled])))
    assert_selector legend, count: 2
    assert_no_selector legend, text: payload[:labels][:extra]

    assert_equal %w[actual scheduled projected extra], payload[:visible].map(&:to_s)
    render_inline(UI::Account::Chart.new(account: loan_account, loan_chart: payload))
    assert_selector legend, count: 4
    assert_selector "#{legend} span.border-dotted", count: 1
    assert_selector legend, text: payload[:labels][:extra]
  end

  # A loan's picker offers a subset of the shared periods, under their own
  # labels. A saved period the loan chart does not offer reads as All.
  test "a loan's period picker offers a subset of the shared periods" do
    loan_account = amortizable_loan_account
    payload = Loan::PayoffChart.new(loan_account.loan, as_of: Date.current).payload

    render_inline(UI::Account::Chart.new(account: loan_account, loan_chart: payload, period: Period.from_key("last_5_years")))

    Loan::PayoffChart::WINDOW_KEYS.each do |key|
      assert_selector "a[href*='period=#{key}'] span", exact_text: Period.from_key(key).label_short, visible: :all
    end
    assert_no_selector "a[href*='period=last_30_days']", visible: :all
    assert_selector "button", text: "5Y"

    render_inline(UI::Account::Chart.new(account: loan_account, loan_chart: payload, period: Period.from_key("last_30_days")))
    assert_selector "button", text: "All"
  end

  # Test 6 at the component: the picker's links keep the extra amount and the
  # tab it came from, or picking a period silently drops the extra line.
  test "a loan's period picker carries the extra amount and its tab" do
    loan_account = amortizable_loan_account
    payload = Loan::PayoffChart.new(loan_account.loan, as_of: Date.current).payload

    render_inline(UI::Account::Chart.new(account: loan_account, loan_chart: payload, extra_payment_amount: "250"))
    links = page.all("a[role='menuitemradio']", visible: :all)
    assert links.any?
    links.each do |link|
      query = Rack::Utils.parse_nested_query(URI.parse(link[:href]).query)
      assert_equal "250", query.dig("extra_payment", "amount"), link[:href]
      assert_equal "extra_repayments", query["tab"], link[:href]
    end

    render_inline(UI::Account::Chart.new(account: loan_account, loan_chart: payload))
    assert_no_selector "a[href*='extra_payment']", visible: :all
  end

  # The loan chart shows the whole life by default, so its change line
  # compares today's balance with the amount borrowed, not with a window the
  # chart is not showing.
  test "a loan's change line compares with the original loan amount" do
    loan_account = amortizable_loan_account
    payload = Loan::PayoffChart.new(loan_account.loan, as_of: Date.current).payload

    render_inline(UI::Account::Chart.new(account: loan_account, loan_chart: payload, period: Period.from_key("last_30_days")))

    assert_text I18n.t("UI.account.chart.loan.since_start")
    assert_no_text Period.from_key("last_30_days").comparison_label
  end

  private
    # A thirty-year mortgage drawn down two years ago, with the opening
    # valuation the account form records, then paid ahead of its contract.
    def amortizable_loan_account
      start_date = 2.years.ago.to_date
      account = Account.create!(
        family: @account.family, name: "Chart Mortgage", balance: 500_000, currency: "USD",
        accountable: Loan.create!(subtype: "mortgage", interest_rate: 3.5, term_months: 360,
                                  rate_type: "fixed", start_date: start_date)
      )
      account.entries.create!(
        name: "Starting balance", amount: 500_000, currency: "USD", date: start_date,
        entryable: Valuation.new(kind: "opening_anchor")
      )
      account.update!(balance: 450_000)
      # Materialised the way the balance calculator writes a liability, so the
      # recorded-balance line has points to draw.
      [ [ start_date, 500_000 ], [ Date.current, 450_000 ] ].each do |date, amount|
        account.balances.create!(date: date, balance: amount, currency: "USD",
                                 start_cash_balance: amount, flows_factor: -1)
      end
      account
    end

    # The two #300 stacking tests are about the family anchor, so check they
    # really got it rather than the 5-year fallback.
    def assert_family_anchor(period)
      activity = Current.family.earliest_activity_date
      assert activity, "the family needs a Transaction or Trade for an anchor"
      assert_equal activity - 1.month, period.start_date
    end

    # 10 shares at $100 market price; gain = 1000 - cost_basis * 10
    def create_holding(cost_basis:)
      Holding.create!(
        account: @account,
        security: securities(:aapl),
        date: Date.current,
        qty: 10,
        price: 100,
        amount: 1000,
        currency: @account.currency,
        cost_basis: cost_basis
      )
    end
end
