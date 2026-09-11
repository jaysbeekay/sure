require "test_helper"

class InvestmentStatementTest < ActiveSupport::TestCase
  include PortfolioFlowTestHelper

  setup do
    @family = families(:empty)
    # families(:empty) defaults to currency "USD"
    @statement = InvestmentStatement.new(@family, user: nil)
  end

  test "portfolio_value and cash_balance with a single-currency family" do
    create_investment_account(balance: 1000, cash_balance: 100)

    assert_equal 1000, @statement.portfolio_value
    assert_equal 100, @statement.cash_balance
    assert_equal 900, @statement.holdings_value
  end

  test "portfolio_value converts foreign-currency accounts to family currency" do
    create_investment_account(balance: 1921.92, cash_balance: -162, currency: "USD")
    create_investment_account(balance: 1000, cash_balance: 1000, currency: "EUR")

    ExchangeRate.create!(
      from_currency: "EUR",
      to_currency: "USD",
      date: Date.current,
      rate: 1.1
    )

    # 1921.92 + 1000 * 1.1 = 3021.92
    assert_in_delta 3021.92, @statement.portfolio_value, 0.001
    # -162 + 1000 * 1.1 = 938
    assert_in_delta 938, @statement.cash_balance, 0.001
    # 3021.92 - 938 = 2083.92
    assert_in_delta 2083.92, @statement.holdings_value, 0.001
  end

  test "portfolio_value falls back to 1:1 when FX rate is missing" do
    create_investment_account(balance: 1921.92, currency: "USD")
    create_investment_account(balance: 1000, currency: "EUR")

    # No ExchangeRate row → rates_for defaults to 1
    assert_in_delta 2921.92, @statement.portfolio_value, 0.001
  end

  test "current_holdings includes holdings from every investment account regardless of currency" do
    usd_account = create_investment_account(balance: 2100, currency: "USD")
    eur_account = create_investment_account(balance: 2000, currency: "EUR")

    usd_security = Security.create!(ticker: "AAPL", name: "Apple")
    eur_security = Security.create!(ticker: "ASML", name: "ASML")

    Holding.create!(
      account: usd_account, security: usd_security, date: Date.current,
      qty: 10, price: 210, amount: 2100, currency: "USD"
    )
    Holding.create!(
      account: eur_account, security: eur_security, date: Date.current,
      qty: 4, price: 500, amount: 2000, currency: "EUR"
    )

    assert_equal 2, @statement.current_holdings.count
  end

  test "top_holdings ranks by family-currency value across currencies" do
    usd_account = create_investment_account(balance: 2100, currency: "USD")
    eur_account = create_investment_account(balance: 2000, currency: "EUR")

    usd_security = Security.create!(ticker: "AAPL", name: "Apple")
    eur_security = Security.create!(ticker: "ASML", name: "ASML")

    Holding.create!(
      account: usd_account, security: usd_security, date: Date.current,
      qty: 10, price: 210, amount: 2100, currency: "USD"
    )
    Holding.create!(
      account: eur_account, security: eur_security, date: Date.current,
      qty: 4, price: 500, amount: 2000, currency: "EUR"
    )

    ExchangeRate.create!(
      from_currency: "EUR", to_currency: "USD",
      date: Date.current, rate: 1.1
    )

    # 2000 EUR = 2200 USD > 2100 USD, so ASML outranks AAPL in family currency
    top = @statement.top_holdings(limit: 2)
    assert_equal %w[ASML AAPL], top.map(&:ticker)
  end

  test "top_holdings rolls up the same security across accounts" do
    ira = create_investment_account(balance: 5000, cash_balance: 0, currency: "USD")
    taxable = create_investment_account(balance: 3000, cash_balance: 0, currency: "USD")
    other = create_investment_account(balance: 2000, cash_balance: 0, currency: "USD")

    aapl = Security.create!(ticker: "AAPL", name: "Apple")
    msft = Security.create!(ticker: "MSFT", name: "Microsoft")

    Holding.create!(
      account: ira, security: aapl, date: Date.current,
      qty: 10, price: 200, amount: 2000, currency: "USD"
    )
    Holding.create!(
      account: taxable, security: aapl, date: Date.current,
      qty: 15, price: 200, amount: 3000, currency: "USD"
    )
    Holding.create!(
      account: other, security: msft, date: Date.current,
      qty: 10, price: 200, amount: 2000, currency: "USD"
    )

    top = @statement.top_holdings(limit: 5)

    assert_equal %w[AAPL MSFT], top.map(&:ticker)
    assert_equal 1, top.count { |row| row.ticker == "AAPL" }
    assert_equal Money.new(5000, "USD"), top.first.amount_money
    # Portfolio total = 5000 + 3000 + 2000 = 10000; AAPL = 50%, MSFT = 20%
    assert_in_delta 50.0, top.first.weight, 0.01
    assert_in_delta 20.0, top.second.weight, 0.01
  end

  test "top_holdings weight is percent of total portfolio including cash" do
    account = create_investment_account(balance: 10_000, cash_balance: 4000, currency: "USD")
    security = Security.create!(ticker: "VOO", name: "Vanguard S&P 500")

    Holding.create!(
      account: account, security: security, date: Date.current,
      qty: 30, price: 200, amount: 6000, currency: "USD"
    )

    top = @statement.top_holdings(limit: 1)

    assert_equal 1, top.size
    # 6000 / 10000 portfolio = 60% (not 100% of holdings)
    assert_in_delta 60.0, top.first.weight, 0.01
  end

  test "top_holdings still lists positions when portfolio_value is stale zero" do
    # Cached Account#balance can lag behind Holding rows; presence must not
    # depend on portfolio_value alone.
    account = create_investment_account(balance: 0, cash_balance: 0, currency: "USD")
    security = Security.create!(ticker: "AAPL", name: "Apple")

    Holding.create!(
      account: account, security: security, date: Date.current,
      qty: 10, price: 200, amount: 2000, currency: "USD"
    )

    assert_equal 0, @statement.portfolio_value

    top = @statement.top_holdings(limit: 5)

    assert_equal 1, top.size
    assert_equal "AAPL", top.first.ticker
    assert_equal Money.new(2000, "USD"), top.first.amount_money
    # Falls back to holdings total as weight denominator when portfolio is 0
    assert_in_delta 100.0, top.first.weight, 0.01
  end

  test "top_holdings computes trends only for the selected limit" do
    large = create_investment_account(balance: 5000, cash_balance: 0)
    small = create_investment_account(balance: 1000, cash_balance: 0)

    top_security = Security.create!(ticker: "TOP1", name: "Top One")
    skipped_security = Security.create!(ticker: "SKIP", name: "Skipped")

    Holding.create!(
      account: large, security: top_security, date: Date.current,
      qty: 50, price: 100, amount: 5000, currency: "USD",
      cost_basis: 90, cost_basis_locked: true
    )
    Holding.create!(
      account: small, security: skipped_security, date: Date.current,
      qty: 10, price: 100, amount: 1000, currency: "USD",
      cost_basis: 90, cost_basis_locked: true
    )

    # Only the one holding in the selected top security should ask for a trend
    Holding.any_instance.expects(:trend).once.returns(nil)

    top = @statement.top_holdings(limit: 1)

    assert_equal %w[TOP1], top.map(&:ticker)
  end

  test "allocation rolls up duplicate securities and weights sum to 100%" do
    ira = create_investment_account(balance: 3000, currency: "USD")
    taxable = create_investment_account(balance: 2000, currency: "USD")

    aapl = Security.create!(ticker: "AAPL", name: "Apple")
    msft = Security.create!(ticker: "MSFT", name: "Microsoft")

    Holding.create!(
      account: ira, security: aapl, date: Date.current,
      qty: 10, price: 100, amount: 1000, currency: "USD"
    )
    Holding.create!(
      account: taxable, security: aapl, date: Date.current,
      qty: 5, price: 100, amount: 500, currency: "USD"
    )
    Holding.create!(
      account: ira, security: msft, date: Date.current,
      qty: 20, price: 100, amount: 2000, currency: "USD"
    )

    allocation = @statement.allocation

    # Portfolio 5000 (account balances) vs holdings 3500: the 1500 the
    # holdings do not explain is reported as a cash row so the weights still
    # sum to 100 and MSFT carries the same 40% here as in top_holdings.
    assert_equal 3, allocation.size
    assert_equal %w[MSFT AAPL CASH], allocation.map(&:ticker)
    assert_equal Money.new(1500, "USD"), allocation.find { |a| a.ticker == "AAPL" }.amount
    assert_in_delta 40.0, allocation.first.weight, 0.01
    assert allocation.last.cash?
    assert_equal Money.new(1500, "USD"), allocation.last.amount
    assert_in_delta 100.0, allocation.sum(&:weight), 0.01
  end

  test "a holding with a negative value cannot push another security's weight over 100" do
    # Holding validates amount >= 0, but Holding::Materializer writes through
    # upsert_all, which skips validations, so an over-sell can land a negative
    # row. Written the same way here.
    account = create_investment_account(balance: 0, cash_balance: 0, currency: "USD")
    good = Security.create!(ticker: "GOOD", name: "Good")
    bad = Security.create!(ticker: "BAD", name: "Bad")
    Holding.create!(account: account, security: good, date: Date.current, qty: 10, price: 100, amount: 1000, currency: "USD")
    Holding.insert_all([ {
      account_id: account.id, security_id: bad.id, date: Date.current,
      qty: -5, price: 100, amount: -500, currency: "USD",
      created_at: Time.current, updated_at: Time.current
    } ])

    top = @statement.top_holdings(limit: 5)

    assert_equal %w[GOOD], top.map(&:ticker), "the corrupt row is left out, not listed at a negative weight"
    assert_in_delta 100.0, top.first.weight, 0.01
    assert_operator top.map(&:weight).max, :<=, 100.0
    assert_in_delta 100.0, @statement.allocation.sum(&:weight), 0.01
  end

  test "weights never exceed 100 when cash is negative" do
    # A margin balance or an unsettled buy makes cash negative, so the
    # portfolio value (960) is below the holdings total (1000). Dividing by
    # portfolio value would report the single holding at 104.17%.
    account = create_investment_account(balance: 960, cash_balance: -40, currency: "USD")
    security = Security.create!(ticker: "VOO", name: "Vanguard S&P 500")

    Holding.create!(
      account: account, security: security, date: Date.current,
      qty: 5, price: 200, amount: 1000, currency: "USD"
    )

    top = @statement.top_holdings(limit: 5)
    allocation = @statement.allocation

    assert_in_delta 100.0, top.first.weight, 0.01
    assert_equal 1, allocation.size, "negative cash must not produce a cash row"
    assert_in_delta 100.0, allocation.first.weight, 0.01
  end

  test "top_holdings and allocation report the same weight for a security" do
    account = create_investment_account(balance: 10_000, cash_balance: 4000, currency: "USD")
    security = Security.create!(ticker: "VOO", name: "Vanguard S&P 500")

    Holding.create!(
      account: account, security: security, date: Date.current,
      qty: 30, price: 200, amount: 6000, currency: "USD"
    )

    top_weight = @statement.top_holdings(limit: 1).first.weight
    allocation = @statement.allocation
    allocation_weight = allocation.find { |row| row.ticker == "VOO" }.weight

    assert_in_delta 60.0, top_weight, 0.01
    assert_equal top_weight, allocation_weight
    assert_equal [ "VOO", "CASH" ], allocation.map(&:ticker)
    assert_in_delta 40.0, allocation.last.weight, 0.01
    assert_equal I18n.t("models.investment_statement.cash"), allocation.last.name
    assert_nil allocation.last.security
    assert_nil allocation.last.trend
  end

  test "allocation omits the cash row when account balances are a stale zero" do
    account = create_investment_account(balance: 0, cash_balance: 0, currency: "USD")
    security = Security.create!(ticker: "AAPL", name: "Apple")

    Holding.create!(
      account: account, security: security, date: Date.current,
      qty: 10, price: 200, amount: 2000, currency: "USD"
    )

    allocation = @statement.allocation

    assert_equal %w[AAPL], allocation.map(&:ticker)
    assert_in_delta 100.0, allocation.first.weight, 0.01
  end

  test "rolls up the same security held in a foreign-currency account in family currency" do
    usd_account = create_investment_account(balance: 2000, currency: "USD")
    eur_account = create_investment_account(balance: 1000, currency: "EUR")
    security = Security.create!(ticker: "AAPL", name: "Apple")

    Holding.create!(
      account: usd_account, security: security, date: Date.current,
      qty: 10, price: 200, amount: 2000, currency: "USD"
    )
    Holding.create!(
      account: eur_account, security: security, date: Date.current,
      qty: 5, price: 200, amount: 1000, currency: "EUR"
    )
    ExchangeRate.create!(from_currency: "EUR", to_currency: "USD", date: Date.current, rate: 1.1)

    top = @statement.top_holdings(limit: 5)

    assert_equal 1, top.size
    # 2000 USD + 1000 EUR * 1.1
    assert_equal Money.new(3100, "USD"), top.first.amount_money
    assert_in_delta 100.0, top.first.weight, 0.01
  end

  test "a holding in an account shared without include_in_finances is not rolled in" do
    shared_user = users(:new_email)
    owned = create_investment_account(balance: 1000, currency: "USD")
    shared_excluded = create_investment_account(balance: 1000, currency: "USD")
    owned.update!(owner: shared_user)
    shared_excluded.share_with!(shared_user, permission: "read_only", include_in_finances: false)
    security = Security.create!(ticker: "AAPL", name: "Apple")

    Holding.create!(
      account: owned, security: security, date: Date.current,
      qty: 5, price: 200, amount: 1000, currency: "USD"
    )
    Holding.create!(
      account: shared_excluded, security: security, date: Date.current,
      qty: 5, price: 200, amount: 1000, currency: "USD"
    )

    statement = InvestmentStatement.new(@family, user: shared_user)
    top = statement.top_holdings(limit: 5)

    assert_equal 1, top.size
    assert_equal Money.new(1000, "USD"), top.first.amount_money,
      "the excluded shared account's holding must not be summed into the user's row"
  end

  test "allocation weights sum to 100% with mixed currencies" do
    usd_account = create_investment_account(balance: 2100, currency: "USD")
    eur_account = create_investment_account(balance: 2000, currency: "EUR")

    usd_security = Security.create!(ticker: "AAPL", name: "Apple")
    eur_security = Security.create!(ticker: "ASML", name: "ASML")

    Holding.create!(
      account: usd_account, security: usd_security, date: Date.current,
      qty: 10, price: 210, amount: 2100, currency: "USD"
    )
    Holding.create!(
      account: eur_account, security: eur_security, date: Date.current,
      qty: 4, price: 500, amount: 2000, currency: "EUR"
    )

    ExchangeRate.create!(
      from_currency: "EUR", to_currency: "USD",
      date: Date.current, rate: 1.1
    )

    allocation = @statement.allocation
    assert_equal 2, allocation.size
    assert_in_delta 100.0, allocation.sum(&:weight), 0.01
    # Every row is labeled in family currency
    assert allocation.all? { |a| a.amount.currency.iso_code == "USD" }
  end

  test "unrealized_gains sums in family currency with mixed-currency holdings" do
    usd_account = create_investment_account(balance: 2100, currency: "USD")
    eur_account = create_investment_account(balance: 2000, currency: "EUR")

    usd_security = Security.create!(ticker: "AAPL", name: "Apple")
    eur_security = Security.create!(ticker: "ASML", name: "ASML")

    Holding.create!(
      account: usd_account, security: usd_security, date: Date.current,
      qty: 10, price: 210, amount: 2100, currency: "USD",
      cost_basis: 200, cost_basis_locked: true
    )
    Holding.create!(
      account: eur_account, security: eur_security, date: Date.current,
      qty: 4, price: 500, amount: 2000, currency: "EUR",
      cost_basis: 450, cost_basis_locked: true
    )

    ExchangeRate.create!(
      from_currency: "EUR", to_currency: "USD",
      date: Date.current, rate: 1.1
    )

    # AAPL unrealized = 2100 - (10 * 200) = 100 USD
    # ASML unrealized = 2000 - (4 * 450) = 200 EUR → 220 USD @ 1.1
    # Total = 320 USD
    assert_in_delta 320, @statement.unrealized_gains, 0.001
    assert_equal "USD", @statement.unrealized_gains_money.currency.iso_code
  end

  test "unrealized_gains_trend is denominated in family currency" do
    usd_account = create_investment_account(balance: 2100, currency: "USD")
    eur_account = create_investment_account(balance: 2000, currency: "EUR")

    usd_security = Security.create!(ticker: "AAPL", name: "Apple")
    eur_security = Security.create!(ticker: "ASML", name: "ASML")

    Holding.create!(
      account: usd_account, security: usd_security, date: Date.current,
      qty: 10, price: 210, amount: 2100, currency: "USD",
      cost_basis: 200, cost_basis_locked: true
    )
    Holding.create!(
      account: eur_account, security: eur_security, date: Date.current,
      qty: 4, price: 500, amount: 2000, currency: "EUR",
      cost_basis: 450, cost_basis_locked: true
    )

    ExchangeRate.create!(
      from_currency: "EUR", to_currency: "USD",
      date: Date.current, rate: 1.1
    )

    trend = @statement.unrealized_gains_trend
    assert_equal "USD", trend.current.currency.iso_code
    assert_equal "USD", trend.previous.currency.iso_code
    # current = 2100 USD + (2000 EUR * 1.1) = 4300 USD
    assert_in_delta 4300, trend.current.amount, 0.001
    # previous (cost basis) = (10 * 200) USD + (4 * 450 * 1.1) EUR→USD = 2000 + 1980 = 3980 USD
    assert_in_delta 3980, trend.previous.amount, 0.001
  end

  test "period_return_trend returns nil when no balance data in period" do
    period = Period.custom(start_date: 10.years.ago.to_date, end_date: 9.years.ago.to_date)
    assert_nil @statement.period_return_trend(period: period)
  end

  test "period_return_trend returns nil when start portfolio value is zero" do
    account = create_investment_account(balance: 5000)
    period = Period.custom(start_date: Date.current.beginning_of_month, end_date: Date.current)
    # Balance only inside the period — nothing strictly before period_start means start_value = 0
    account.balances.create!(
      date: period.date_range.begin,
      balance: 5000,
      currency: @family.currency,
      net_market_flows: 200
    )
    assert_nil @statement.period_return_trend(period: period)
  end

  test "period_return_trend returns Trend with correct absolute and percent return" do
    account = create_investment_account(balance: 10_500)
    period = Period.custom(start_date: Date.current.beginning_of_month, end_date: Date.current)

    # Pre-period row: start_non_cash_balance drives end_balance (virtual stored column)
    account.balances.create!(
      date: period.date_range.begin - 1.day,
      balance: 10_000,
      currency: @family.currency,
      start_non_cash_balance: 10_000,
      net_market_flows: 0
    )
    # In-period row: 500 of market gains
    account.balances.create!(
      date: period.date_range.begin,
      balance: 10_500,
      currency: @family.currency,
      start_non_cash_balance: 10_000,
      net_market_flows: 500
    )

    trend = @statement.period_return_trend(period: period)
    assert_not_nil trend
    assert_in_delta 500, trend.value.amount, 1
    assert_in_delta 5.0, trend.percent, 0.1
  end

  test "value_series sums the per-account balance series on every date of the period" do
    period = Period.custom(start_date: 10.days.ago.to_date, end_date: 5.days.ago.to_date)

    usd = create_investment_account(balance: 1000, currency: "USD")
    eur = create_investment_account(balance: 500, currency: "EUR")
    closed = create_investment_account(balance: 300, currency: "USD")

    create_balance(usd, date: 12.days.ago.to_date, amount: 1000)
    create_balance(usd, date: 7.days.ago.to_date, amount: 1200)
    create_balance(eur, date: 12.days.ago.to_date, amount: 500, currency: "EUR")
    create_balance(closed, date: 12.days.ago.to_date, amount: 300)

    closed.update!(status: "disabled", disabled_at: 7.days.ago)

    (12.days.ago.to_date..Date.current).each do |date|
      ExchangeRate.create!(from_currency: "EUR", to_currency: "USD", date: date, rate: 1.2)
    end

    scope = @statement.historical_scope
    assert_equal 3, scope.account_ids.size

    # Expected windows are derived here, independently of HistoricalScope, so
    # this asserts the cut-off as well as the summation.
    expected_windows = { closed.id => closed.disabled_at.to_date - 1.day }

    expected = Hash.new(0)
    [ usd.id, eur.id, closed.id ].each do |account_id|
      series = Balance::ChartSeriesBuilder.new(
        account_ids: [ account_id ],
        account_active_until_dates: expected_windows.slice(account_id),
        currency: "USD",
        period: period,
        favorable_direction: "up"
      ).balance_series

      series.values.each { |v| expected[v.date] += v.value.amount }
    end

    actual = @statement.value_series(period: period)

    assert_equal expected.keys.sort, actual.values.map(&:date).sort
    actual.values.each do |value|
      assert_in_delta expected[value.date], value.value.amount, 0.001,
        "portfolio value on #{value.date} should equal the sum of the per-account series"
    end
  end

  test "a disabled account stops contributing to value_series after its cut-off date" do
    period = Period.custom(start_date: 10.days.ago.to_date, end_date: Date.current)

    open_account = create_investment_account(balance: 1000, currency: "USD")
    closed = create_investment_account(balance: 300, currency: "USD")

    create_balance(open_account, date: 12.days.ago.to_date, amount: 1000)
    create_balance(closed, date: 12.days.ago.to_date, amount: 300)

    closed.update!(status: "disabled", disabled_at: 7.days.ago)
    cutoff = 8.days.ago.to_date

    by_date = @statement.value_series(period: period).values.index_by(&:date)

    assert_in_delta 1300, by_date[cutoff].value.amount, 0.001,
      "on the cut-off date the disabled account still counts"
    assert_in_delta 1000, by_date[cutoff + 1.day].value.amount, 0.001,
      "after the cut-off date the disabled account no longer counts"
    assert_in_delta 1000, by_date[Date.current].value.amount, 0.001
  end

  test "value_series memoizes the builder per period on the instance" do
    create_investment_account(balance: 1000, currency: "USD")
    period = Period.custom(start_date: 10.days.ago.to_date, end_date: Date.current)

    series = Series.new(
      start_date: period.start_date, end_date: period.end_date,
      interval: period.interval, values: [], favorable_direction: "up"
    )
    builder = stub(balance_series: series)
    Balance::ChartSeriesBuilder.expects(:new).once.returns(builder)

    assert_same series, @statement.value_series(period: period)
    assert_same series, @statement.value_series(period: period)
  end

  test "holdings_value_series delegates to the builder's holdings balance series" do
    create_investment_account(balance: 1000, currency: "USD")
    period = Period.custom(start_date: 10.days.ago.to_date, end_date: Date.current)

    series = Series.new(
      start_date: period.start_date, end_date: period.end_date,
      interval: period.interval, values: [], favorable_direction: "up"
    )
    builder = mock
    builder.expects(:holdings_balance_series).once.returns(series)
    Balance::ChartSeriesBuilder.expects(:new).once.returns(builder)

    assert_same series, @statement.holdings_value_series(period: period)
  end

  test "gains_series delegates to the builder's gains series" do
    create_investment_account(balance: 1000, currency: "USD")
    period = Period.custom(start_date: 10.days.ago.to_date, end_date: Date.current)

    series = Series.new(
      start_date: period.start_date, end_date: period.end_date,
      interval: period.interval, values: [], favorable_direction: "up"
    )
    builder = mock
    builder.expects(:gains_series).once.returns(series)
    Balance::ChartSeriesBuilder.expects(:new).once.returns(builder)

    assert_same series, @statement.gains_series(period: period)
  end

  test "value_series is historical where portfolio_value is live, so a closed account diverges" do
    # The series is charted from the historical scope, so a disabled broker
    # keeps its balance up to its cut-off; portfolio_value only sees visible
    # accounts and drops it immediately.
    period = Period.custom(start_date: 10.days.ago.to_date, end_date: 5.days.ago.to_date)

    open_account = create_investment_account(balance: 1000, currency: "USD")
    closed = create_investment_account(balance: 300, currency: "USD")

    create_balance(open_account, date: 12.days.ago.to_date, amount: 1000)
    create_balance(closed, date: 12.days.ago.to_date, amount: 300)

    closed.update!(status: "disabled", disabled_at: 2.days.ago)

    assert_equal 1000, @statement.portfolio_value
    assert_in_delta 1300, @statement.value_series(period: period).values.last.value.amount, 0.001
  end

  test "value_series returns a zero series when there are no investment accounts" do
    period = Period.custom(start_date: 10.days.ago.to_date, end_date: Date.current)

    series = @statement.value_series(period: period)

    assert_predicate series.values, :any?
    assert series.values.all? { |v| v.value.amount.zero? }
  end

  test "totals skips cache when there are no investment accounts" do
    Rails.cache.expects(:fetch).never

    totals = @statement.totals(period: Period.current_month)

    assert_equal Money.new(0, "USD"), totals.contributions
    assert_equal Money.new(0, "USD"), totals.withdrawals
    assert_equal Money.new(0, "USD"), totals.dividends
    assert_equal Money.new(0, "USD"), totals.interest
    assert_equal 0, totals.trades_count
  end

  test "totals aggregate directly from trade entries" do
    # Use the full current month: a month-to-date period collapses to a single
    # day on the 1st, which would drop the start_date + 1.day trade below.
    period = Period.custom(start_date: Date.current.beginning_of_month, end_date: Date.current.end_of_month)
    shared_user = users(:new_email)
    investment_account = create_investment_account(balance: 500)
    hidden_account = create_investment_account(balance: 500)
    investment_account.share_with!(shared_user, permission: "read_only", include_in_finances: true)

    create_trade(account: investment_account, qty: 2, amount: 120, date: period.start_date)
    create_trade(account: investment_account, qty: -1, amount: -40, date: period.start_date + 1.day)
    create_trade(account: investment_account, qty: 1, amount: 999, date: period.start_date - 1.day)
    create_trade(account: hidden_account, qty: 1, amount: 9999, date: period.start_date)

    statement = InvestmentStatement.new(@family, user: shared_user)
    totals = nil
    queries = capture_sql_queries { totals = statement.totals(period: period) }

    assert_equal Money.new(120, "USD"), totals.contributions
    assert_equal Money.new(40, "USD"), totals.withdrawals
    assert_equal 2, totals.trades_count

    aggregate_queries = queries.grep(/SUM\(CASE WHEN trades\.qty > 0/)
    assert_equal 1, aggregate_queries.size
    assert_includes aggregate_queries.first, "FROM entries LEFT JOIN trades"
    assert_includes aggregate_queries.first, "entries.entryable_type = 'Trade'"
    assert_includes aggregate_queries.first, "entries.account_id IN"
    assert_includes aggregate_queries.first, "entries.excluded = false"
    assert_no_match(/FROM \(SELECT "trades"\.\*/, aggregate_queries.first)
    # account_ids is pre-scoped to the family's visible accounts, so the
    # aggregate trusts that input and no longer joins back to accounts.
    assert_no_match(/JOIN accounts/, aggregate_queries.first)
  end

  test "totals aggregate dividend and interest income from income trades" do
    period = Period.custom(start_date: Date.current.beginning_of_month, end_date: Date.current.end_of_month)
    account = create_investment_account(balance: 500)

    create_income_trade(account: account, label: "Dividend", amount: 50, date: period.start_date)
    create_income_trade(account: account, label: "Dividend", amount: 25, date: period.start_date + 1.day)
    create_income_trade(account: account, label: "Interest", amount: 10, date: period.start_date)
    # Outside the period, must not be counted
    create_income_trade(account: account, label: "Dividend", amount: 999, date: period.start_date - 1.day)

    totals = @statement.totals(period: period)

    assert_equal Money.new(75, "USD"), totals.dividends
    assert_equal Money.new(10, "USD"), totals.interest
    assert_equal Money.new(85, "USD"), totals.total_income
  end

  test "income trades are not counted as contributions or withdrawals" do
    period = Period.custom(start_date: Date.current.beginning_of_month, end_date: Date.current.end_of_month)
    account = create_investment_account(balance: 500)

    create_trade(account: account, qty: 2, amount: 120, date: period.start_date)
    create_income_trade(account: account, label: "Dividend", amount: 50, date: period.start_date)

    totals = @statement.totals(period: period)

    # qty: 0 keeps income out of both direction branches
    assert_equal Money.new(120, "USD"), totals.contributions
    assert_equal Money.new(0, "USD"), totals.withdrawals
    assert_equal Money.new(50, "USD"), totals.dividends
  end

  test "a buy relabeled to Dividend is counted as income only, not also as a contribution" do
    # The activity-label quick editor permits changing the label on its own and
    # leaves qty untouched, so an income-labeled trade can carry qty > 0. It must
    # not land in both the direction bucket and the income bucket.
    period = Period.custom(start_date: Date.current.beginning_of_month, end_date: Date.current.end_of_month)
    account = create_investment_account(balance: 500)

    trade_entry = create_trade(account: account, qty: 2, amount: 120, date: period.start_date)
    trade_entry.trade.update!(investment_activity_label: "Dividend")

    totals = @statement.totals(period: period)

    assert_equal Money.new(0, "USD"), totals.contributions
    assert_equal Money.new(120, "USD"), totals.dividends
    assert_equal Money.new(120, "USD"), totals.total_income
  end

  test "a sell relabeled to Interest is counted as income only, not also as a withdrawal" do
    period = Period.custom(start_date: Date.current.beginning_of_month, end_date: Date.current.end_of_month)
    account = create_investment_account(balance: 500)

    trade_entry = create_trade(account: account, qty: -1, amount: -40, date: period.start_date)
    trade_entry.trade.update!(investment_activity_label: "Interest")

    totals = @statement.totals(period: period)

    assert_equal Money.new(0, "USD"), totals.withdrawals
    assert_equal Money.new(40, "USD"), totals.interest
  end

  test "labeled non-income trades still count by direction" do
    # Only Dividend/Interest are excluded from the direction buckets; Buy, Sell
    # and Reinvestment keep their existing contribution/withdrawal treatment.
    period = Period.custom(start_date: Date.current.beginning_of_month, end_date: Date.current.end_of_month)
    account = create_investment_account(balance: 500)

    buy = create_trade(account: account, qty: 2, amount: 120, date: period.start_date)
    buy.trade.update!(investment_activity_label: "Buy")
    reinvest = create_trade(account: account, qty: 1, amount: 30, date: period.start_date)
    reinvest.trade.update!(investment_activity_label: "Reinvestment")

    totals = @statement.totals(period: period)

    assert_equal Money.new(150, "USD"), totals.contributions
    # Reinvestment is deliberately not folded into dividend income; doing so
    # would require removing it from contributions too.
    assert_equal Money.new(0, "USD"), totals.dividends
  end

  test "totals convert foreign-currency dividends into family currency" do
    period = Period.custom(start_date: Date.current.beginning_of_month, end_date: Date.current.end_of_month)
    account = create_investment_account(balance: 500, currency: "EUR")

    ExchangeRate.create!(
      from_currency: "EUR",
      to_currency: "USD",
      date: period.start_date,
      rate: 1.1
    )

    create_income_trade(account: account, label: "Dividend", amount: 100, date: period.start_date)

    totals = @statement.totals(period: period)

    assert_equal Money.new(110, "USD"), totals.dividends
  end

  test "total_dividends and total_interest expose all-time income" do
    account = create_investment_account(balance: 500)

    create_income_trade(account: account, label: "Dividend", amount: 40, date: 2.years.ago.to_date)
    create_income_trade(account: account, label: "Interest", amount: 5, date: Date.current)

    assert_equal 40, @statement.total_dividends
    assert_equal 5, @statement.total_interest
  end

  test "current_holdings memoizes so repeated dashboard-style calls issue a single query" do
    account = create_investment_account(balance: 2100, currency: "USD")
    security = Security.create!(ticker: "AAPL", name: "Apple")

    Holding.create!(
      account: account, security: security, date: Date.current,
      qty: 10, price: 210, amount: 2100, currency: "USD"
    )

    queries = capture_sql_queries do
      @statement.current_holdings
      @statement.top_holdings(limit: 5)
      @statement.allocation
      @statement.day_change
    end

    holdings_queries = queries.grep(/DISTINCT ON \(holdings\.account_id, holdings\.security_id\) holdings\.id/)
    assert_equal 1, holdings_queries.size,
      "current_holdings should only run its DISTINCT ON query once per instance, not once per caller"
  end

  test "current_holdings memoizes the empty (no investment accounts) case too" do
    queries = capture_sql_queries do
      @statement.current_holdings
      @statement.current_holdings
    end

    account_queries = queries.grep(/FROM "accounts"/)
    assert_equal 1, account_queries.size,
      "the investment_accounts lookup backing current_holdings should only run once, even for the empty case"
  end

  test "contributions and withdrawals are the cash the trade entry records" do
    period = Period.custom(start_date: Date.current.beginning_of_month, end_date: Date.current.end_of_month)
    account = create_investment_account(balance: 500)

    # Trade::CreateForm shape: amount = qty * price + fee = 1005, the cash out.
    create_portfolio_trade(account: account, qty: 10, price: 100, fee: 5, date: period.start_date)
    # Kraken / Binance-spot shape: amount = qty * price = 1000, fee reported
    # separately, so the cash out was 1005 and the entry records 1000.
    create_portfolio_trade(account: account, qty: 10, price: 100, fee: 5, date: period.start_date, fee_in_amount: false)

    totals = @statement.totals(period: period)

    assert_equal Money.new(2005, "USD"), totals.contributions
    assert_equal Money.new(10, "USD"), totals.fees
  end

  test "a stale, zero or foreign-currency price cannot move contributions or withdrawals" do
    # Each of these shapes broke an earlier version of this aggregation that
    # measured the cash against qty * price: a price far above the amount
    # doubled a contribution, a price that rounds to zero erased a sale, and a
    # sell whose quantity is already net of its fee (Binance P2P) had the fee
    # charged twice. The cash on the entry is the only figure reported now.
    period = Period.custom(start_date: Date.current.beginning_of_month, end_date: Date.current.end_of_month)
    account = create_investment_account(balance: 500)

    # A buy whose stored price is stale (or quoted in another currency).
    create_portfolio_trade(account: account, qty: 10, price: 200, fee: 0, date: period.start_date, fee_in_amount: false)
      .update!(amount: 1000)
    # A sale of a sub-1e-10 crypto: trades.price is numeric(19,10), so the
    # price stores as 0 while the cash is real.
    create_portfolio_trade(account: account, qty: -100_000_000_000, price: 0, fee: 0, date: period.start_date, fee_in_amount: false)
      .update!(amount: -1000)
    # Binance P2P sell: amount is the gross fiat, qty is already net of the
    # crypto fee, so qty * price is the amount less the fee.
    create_portfolio_trade(account: account, qty: -99, price: 10, fee: 10, date: period.start_date, fee_in_amount: false)
      .update!(amount: -1000)

    totals = @statement.totals(period: period)

    assert_equal Money.new(1000, "USD"), totals.contributions, "a stale price must not inflate the contribution"
    assert_equal Money.new(2000, "USD"), totals.withdrawals, "neither sale may shrink or vanish"
    assert_equal Money.new(10, "USD"), totals.fees
  end

  test "fees sum Fee-labelled entries and transfer fee legs alongside trades.fee" do
    period = Period.custom(start_date: Date.current.beginning_of_month, end_date: Date.current.end_of_month)
    account = create_investment_account(balance: 500)
    checking = @family.accounts.create!(name: "Checking", balance: 5000, currency: "USD", accountable: Depository.new)

    create_portfolio_trade(account: account, qty: 1, price: 100, fee: 2, date: period.start_date)
    # IBKR / Questrade commission: a Fee-labelled Transaction
    create_labelled_transaction(account: account, label: "Fee", amount: 1.5, date: period.start_date)
    # A Fee-labelled trade counts its amount, not its (zero) fee column
    create_portfolio_trade(account: account, qty: 0, price: 0, label: "Fee", date: period.start_date).update!(amount: 9.95)
    # The fee leg of a transfer into the account, which lands in the source account (not counted here)
    create_linked_transfer(family: @family, from: checking, to: account, amount: 300, date: period.start_date, source_fee_amount: 4)
    # An unrelated deposit and buy-labelled cash movement contribute nothing to fees
    create_labelled_transaction(account: account, label: "Contribution", amount: -300, date: period.start_date)

    totals = @statement.totals(period: period)

    assert_equal Money.new(13.45, "USD"), totals.fees
    # The buy's amount is 100 + 2 fee, the cash that left; the fee is inside
    # the contribution and in `fees`, which is what P21 says of a writer that
    # folds its fee in.
    assert_equal Money.new(102, "USD"), totals.contributions
    assert_equal 2, totals.trades_count
    assert_equal 13.45, @statement.total_fees
  end

  test "dividends and interest count the transaction shapes providers write" do
    period = Period.custom(start_date: Date.current.beginning_of_month, end_date: Date.current.end_of_month)
    account = create_investment_account(balance: 500)

    create_income_trade(account: account, label: "Dividend", amount: 50, date: period.start_date)
    create_income_transaction(account: account, label: "Dividend", amount: 12.5, date: period.start_date, extra_shape: :flat)
    create_income_transaction(account: account, label: "Interest", amount: 4, date: period.start_date, extra_shape: :none)
    # PlaidAccount::Investments::TransactionsProcessor writes a dividend as
    # a qty-0 trade with amount 0 * price, so its cash is not recoverable
    # here (its `price` is a per-share figure, not the payment). It is
    # income with amount 0 until jaysbeekay/sure#123 fixes the processor; the 62.5 below
    # deliberately excludes it.
    create_plaid_dividend_trade(account: account, date: period.start_date)
    # Pending income is not counted until it posts
    create_labelled_transaction(account: account, label: "Dividend", amount: -99, date: period.start_date, extra: { "plaid" => { "pending" => true } })
    # A labelled transaction outside the period is not counted
    create_income_transaction(account: account, label: "Dividend", amount: 999, date: period.start_date - 1.day, extra_shape: :flat)

    totals = @statement.totals(period: period)

    assert_equal Money.new(62.5, "USD"), totals.dividends
    assert_equal Money.new(4, "USD"), totals.interest
    assert_equal Money.new(66.5, "USD"), totals.total_income
    assert_equal Money.new(0, "USD"), totals.contributions
  end

  # The classifier reads a pending flag without casting it: `::boolean` raises
  # on a value PostgreSQL cannot parse ("maybe") and disagrees with ActiveModel
  # on one it can ("no"). Totals used the cast, so a single such flag aborted
  # the family's whole aggregation -- and every page that reads it -- while the
  # classifier answered the same entry without complaint.
  test "totals read a non-boolean pending flag the way the flow classifier does" do
    period = Period.custom(start_date: Date.current.beginning_of_month, end_date: Date.current.end_of_month)
    account = create_investment_account(balance: 500)
    entries = { "maybe" => -11, "no" => -13, "false" => -17, "0" => -19 }.map do |flag, amount|
      create_labelled_transaction(account: account, label: "Dividend", amount: amount, date: period.start_date,
                                  extra: { "plaid" => { "pending" => flag } })
    end

    totals = @statement.totals(period: period)

    classifier = Portfolio::FlowClassifier.new(scope_account_ids: [ account.id ])
    posted = entries.select { |entry| classifier.classify(entry.reload) == :income }
    assert_equal Money.new(36, "USD"), totals.dividends, "\"false\" and \"0\" have posted; \"maybe\" and \"no\" are pending"
    assert_equal posted.sum { |entry| entry.amount.abs }, totals.dividends.amount
  end

  # "Never also its fee column" guards a double count. When the amount is zero
  # the column is the only record of the fee, and reading the amount alone
  # dropped it from the total.
  test "a Fee-labelled trade with no amount counts its fee column, and never both" do
    period = Period.custom(start_date: Date.current.beginning_of_month, end_date: Date.current.end_of_month)
    account = create_investment_account(balance: 500)

    create_portfolio_trade(account: account, qty: 0, price: 0, label: "Fee", fee: 7, fee_in_amount: false, date: period.start_date)
    create_portfolio_trade(account: account, qty: 0, price: 0, label: "Fee", fee: 5, fee_in_amount: true, date: period.start_date)

    assert_equal Money.new(12, "USD"), @statement.totals(period: period).fees
  end

  test "totals read their income and fee labels from the flow classifier" do
    period = Period.custom(start_date: Date.current.beginning_of_month, end_date: Date.current.end_of_month)
    account = create_investment_account(balance: 500)
    create_portfolio_trade(account: account, qty: 2, price: 60, label: "Other", date: period.start_date)

    assert_equal Money.new(120, "USD"), @statement.totals(period: period).contributions

    # Widen the classifier's income set and the same trade leaves the
    # contribution bucket without Totals being edited.
    Portfolio::FlowClassifier.stubs(:labels_for).with(:income).returns([ "Dividend", "Interest", "Other" ])
    Portfolio::FlowClassifier.stubs(:labels_for).with(:fee).returns([ "Fee" ])

    assert_equal Money.new(0, "USD"), InvestmentStatement.new(@family, user: nil).totals(period: period).contributions
  end

  test "the income buckets cover every income label the classifier knows" do
    assert_equal %w[Dividend Interest], Portfolio::FlowClassifier.labels_for(:income),
      "Totals splits income into dividends and interest by literal label; a new income label needs its own bucket there"
  end

  test "totals cache key carries the v4 aggregation version" do
    create_investment_account(balance: 500)
    seen_keys = []
    Rails.cache.stubs(:fetch).with { |*args| seen_keys << Array(args.first); true }.returns(
      { contributions: 0, withdrawals: 0, dividends: 0, interest: 0, fees: 0, trades_count: 0 }
    )

    @statement.totals(period: Period.current_month)

    assert_equal 1, seen_keys.size
    assert_includes seen_keys.first, "totals_query/v4"
  end

  test "series cache key changes when a share is revoked" do
    shared_user = users(:new_email)
    account = create_investment_account(balance: 1000)
    share = account.share_with!(shared_user, permission: "read_only", include_in_finances: true)
    period = Period.last_30_days

    before = InvestmentStatement.new(@family, user: shared_user).send(:series_cache_key, :value, period)
    share.destroy!
    after = InvestmentStatement.new(@family, user: shared_user).send(:series_cache_key, :value, period)

    assert_not_equal before, after, "a revoked share must not keep serving the series it was part of"
  end

  test "gains series cache key changes when a holding's cost basis is edited by hand" do
    account = create_investment_account(balance: 1000)
    security = Security.create!(ticker: "AAPL", name: "Apple")
    holding = Holding.create!(
      account: account, security: security, date: Date.current,
      qty: 10, price: 100, amount: 1000, currency: "USD"
    )
    period = Period.last_30_days

    gains_before = InvestmentStatement.new(@family).send(:series_cache_key, :gains, period)
    value_before = InvestmentStatement.new(@family).send(:series_cache_key, :value, period)

    # HoldingsController#update writes the holding alone: no sync completes
    # and the account row is untouched, so the family key does not move.
    travel 1.second do
      holding.set_manual_cost_basis!(90)
    end

    gains_after = InvestmentStatement.new(@family).send(:series_cache_key, :gains, period)
    value_after = InvestmentStatement.new(@family).send(:series_cache_key, :value, period)

    assert_not_equal gains_before, gains_after, "a cost-basis edit must not keep serving the gains built before it"
    assert_equal value_before, value_after, "the value series reads balances, not holdings, and keeps its key"
  end

  test "gains series cache key changes when a holding is deleted" do
    account = create_investment_account(balance: 1000)
    security = Security.create!(ticker: "AAPL", name: "Apple")
    holding = Holding.create!(
      account: account, security: security, date: Date.current,
      qty: 10, price: 100, amount: 1000, currency: "USD"
    )
    period = Period.last_30_days

    before = InvestmentStatement.new(@family).send(:series_cache_key, :gains, period)
    holding.destroy!
    after = InvestmentStatement.new(@family).send(:series_cache_key, :gains, period)

    assert_not_equal before, after
  end

  test "a security whose holdings carry no value is omitted from top_holdings and allocation" do
    account = create_investment_account(balance: 1000, cash_balance: 0, currency: "USD")
    priced = Security.create!(ticker: "AAPL", name: "Apple")
    unpriced = Security.create!(ticker: "NOPX", name: "Not Yet Priced")

    Holding.create!(
      account: account, security: priced, date: Date.current,
      qty: 10, price: 100, amount: 1000, currency: "USD"
    )
    # A position with no price yet: qty is real, amount is 0.
    Holding.create!(
      account: account, security: unpriced, date: Date.current,
      qty: 10, price: 0, amount: 0, currency: "USD"
    )

    assert_equal %w[AAPL], @statement.top_holdings(limit: 5).map(&:ticker)
    assert_equal %w[AAPL], @statement.allocation.map(&:ticker)
    assert_in_delta 100.0, @statement.allocation.sum(&:weight), 0.01
  end

  test "a rolled-up return is measured over the holdings whose cost basis is known" do
    ira = create_investment_account(balance: 1000, currency: "USD")
    taxable = create_investment_account(balance: 2000, currency: "USD")
    aapl = Security.create!(ticker: "AAPL", name: "Apple")
    msft = Security.create!(ticker: "MSFT", name: "Microsoft")

    Holding.create!(
      account: ira, security: aapl, date: Date.current,
      qty: 10, price: 100, amount: 1000, currency: "USD",
      cost_basis: 80, cost_basis_locked: true
    )
    # Same security, no stored cost basis and no trades: avg_cost is nil.
    Holding.create!(
      account: taxable, security: aapl, date: Date.current,
      qty: 10, price: 100, amount: 1000, currency: "USD"
    )
    Holding.create!(
      account: taxable, security: msft, date: Date.current,
      qty: 10, price: 100, amount: 1000, currency: "USD"
    )

    aapl_row, msft_row = @statement.top_holdings(limit: 2)

    assert_equal "AAPL", aapl_row.ticker
    assert_equal Money.new(2000, "USD"), aapl_row.amount_money, "the amount counts every holding"
    assert_equal Money.new(1000, "USD"), aapl_row.trend.current, "the return covers only the holding with a known cost"
    assert_equal Money.new(800, "USD"), aapl_row.trend.previous
    assert_in_delta 25.0, aapl_row.trend.percent, 0.01

    assert_equal "MSFT", msft_row.ticker
    assert_nil msft_row.trend, "no known cost basis, no return"
  end

  test "allocation issues no per-holding trade queries when cost basis is stored" do
    account = create_investment_account(balance: 3000, currency: "USD")
    3.times do |i|
      Holding.create!(
        account: account, security: Security.create!(ticker: "STK#{i}", name: "Stock #{i}"),
        date: Date.current, qty: 10, price: 100, amount: 1000, currency: "USD",
        cost_basis: 90, cost_basis_locked: true
      )
    end

    queries = capture_sql_queries { @statement.allocation }

    assert_equal 3, @statement.allocation.size
    assert_empty queries.grep(/FROM "trades"/), "Holding#trend must read the stored cost basis, not fall back to trades"
  end

  test "previous_holdings loads the prior snapshot of every holding in one query" do
    ira = create_investment_account(balance: 5000)
    taxable = create_investment_account(balance: 3000)
    aapl = Security.create!(ticker: "AAPL", name: "Apple")
    msft = Security.create!(ticker: "MSFT", name: "Microsoft")

    [ [ ira, aapl, 10 ], [ ira, msft, 5 ], [ taxable, aapl, 4 ] ].each do |account, security, qty|
      Holding.create!(account: account, security: security, date: 2.days.ago.to_date, qty: qty, price: 100, amount: qty * 100, currency: "USD")
      Holding.create!(account: account, security: security, date: 1.day.ago.to_date, qty: qty, price: 110, amount: qty * 110, currency: "USD")
      Holding.create!(account: account, security: security, date: Date.current, qty: qty, price: 120, amount: qty * 120, currency: "USD")
    end
    # A holding with no prior snapshot has no day change.
    only_today = Security.create!(ticker: "NEW", name: "New")
    Holding.create!(account: taxable, security: only_today, date: Date.current, qty: 1, price: 50, amount: 50, currency: "USD")

    @statement.current_holdings.to_a
    queries = capture_sql_queries { @statement.previous_holdings; @statement.day_change }
    holdings_queries = queries.grep(/FROM "holdings"/)

    assert_equal 1, holdings_queries.size, "previous snapshots must come from one query, not one per holding"

    previous = @statement.previous_holdings
    assert_equal 3, previous.size
    assert_equal 1.day.ago.to_date, previous[[ ira.id, aapl.id ]].date
    assert_nil previous[[ taxable.id, only_today.id ]]

    # Same answer as the per-holding lookup, summed in family currency:
    # today 19 * 120 = 2280 vs yesterday 19 * 110 = 2090.
    day_change = @statement.day_change
    assert_equal Money.new(2280, "USD"), day_change.current
    assert_equal Money.new(2090, "USD"), day_change.previous
    per_holding = @statement.current_holdings.filter_map { |h| h.day_change }
    assert_equal per_holding.sum { |t| t.current.amount }, day_change.current.amount
  end

  test "value_series does not chart leading zeros before a linked account's first supported history" do
    period = Period.custom(start_date: 10.days.ago.to_date, end_date: Date.current)
    account = create_investment_account(balance: 1000)
    first_synced = 4.days.ago.to_date

    # Balance rows exist for every day (zeros before the connection), and the
    # first provider-sourced entry dates the real history.
    (0..10).each { |offset| create_balance(account, date: 10.days.ago.to_date + offset, amount: offset >= 6 ? 1000 : 0) }
    account.entries.create!(date: first_synced, name: "Deposit", amount: -1000, currency: "USD", source: "plaid", entryable: Transaction.new)

    series = @statement.value_series(period: period)

    assert_equal first_synced, series.values.first.date
    assert series.values.none? { |v| v.date < first_synced }
    assert_equal 1000, series.values.first.value.amount
  end

  test "holdings_table_rows measures a row's return over the positions whose cost basis is known" do
    ira = create_investment_account(balance: 5000, cash_balance: 500)
    taxable = create_investment_account(balance: 3000)
    aapl = Security.create!(ticker: "AAPL", name: "Apple")
    msft = Security.create!(ticker: "MSFT", name: "Microsoft")

    Holding.create!(account: ira, security: aapl, date: 1.day.ago.to_date, qty: 10, price: 190, amount: 1900, currency: "USD", cost_basis: 150, cost_basis_locked: true)
    Holding.create!(account: ira, security: aapl, date: Date.current, qty: 10, price: 200, amount: 2000, currency: "USD", cost_basis: 150, cost_basis_locked: true)
    # No stored basis and no trades in the second account, so Holding#avg_cost
    # is nil there and that position is outside the row's return.
    Holding.create!(account: taxable, security: aapl, date: Date.current, qty: 5, price: 200, amount: 1000, currency: "USD")
    Holding.create!(account: ira, security: msft, date: Date.current, qty: 4, price: 500, amount: 2000, currency: "USD", cost_basis: 400, cost_basis_locked: true)

    rows = @statement.holdings_table_rows

    assert_equal %w[AAPL MSFT], rows.map(&:ticker)
    aapl_row, msft_row = rows

    assert_equal 2, aapl_row.accounts_count
    assert_equal 15, aapl_row.qty
    assert_equal Money.new(3000, "USD"), aapl_row.amount_money
    assert aapl_row.missing_cost_basis, "one position has no known basis, so the row still warns"
    # Partial credit, the rule the unrealised-gains KPI and combined_holding_trend
    # already use (P28): cost and return cover the 10 shares whose basis is
    # known (2000 now against 1500 cost), not the 5 that have none.
    assert_equal Money.new(150, "USD"), aapl_row.avg_cost
    assert_equal Money.new(2000, "USD"), aapl_row.unrealized.current
    assert_equal Money.new(1500, "USD"), aapl_row.unrealized.previous
    assert_equal Money.new(500, "USD"), aapl_row.unrealized.value
    # Day change from the one position with a prior snapshot: 2000 vs 1900.
    assert_equal Money.new(100, "USD"), aapl_row.day_change.value

    assert_not msft_row.missing_cost_basis
    assert_equal Money.new(400, "USD"), msft_row.avg_cost
    assert_equal Money.new(400, "USD"), msft_row.unrealized.value
    assert_nil msft_row.day_change
    # Weights use the same denominator as top_holdings: max(8000, 5000).
    assert_in_delta 37.5, aapl_row.weight, 0.01
    assert_in_delta 25.0, msft_row.weight, 0.01
  end

  test "holdings_table_rows sorts by a whitelisted key and puts rows without the figure last" do
    account = create_investment_account(balance: 6000)
    with_basis = Security.create!(ticker: "BBB", name: "Beta")
    without_basis = Security.create!(ticker: "AAA", name: "Alpha")
    big = Security.create!(ticker: "CCC", name: "Gamma")

    Holding.create!(account: account, security: with_basis, date: Date.current, qty: 1, price: 1000, amount: 1000, currency: "USD", cost_basis: 800, cost_basis_locked: true)
    Holding.create!(account: account, security: without_basis, date: Date.current, qty: 1, price: 2000, amount: 2000, currency: "USD")
    Holding.create!(account: account, security: big, date: Date.current, qty: 1, price: 3000, amount: 3000, currency: "USD", cost_basis: 3500, cost_basis_locked: true)

    assert_equal %w[CCC AAA BBB], @statement.holdings_table_rows.map(&:ticker), "default is value desc"
    assert_equal %w[BBB AAA CCC], @statement.holdings_table_rows(sort: "value", dir: "asc").map(&:ticker)
    assert_equal %w[AAA BBB CCC], @statement.holdings_table_rows(sort: "name", dir: "asc").map(&:ticker)
    assert_equal %w[CCC BBB AAA], @statement.holdings_table_rows(sort: "name", dir: "desc").map(&:ticker)
    # Return: BBB +200, CCC -500, AAA unknown and therefore last both ways.
    assert_equal %w[BBB CCC AAA], @statement.holdings_table_rows(sort: "return", dir: "desc").map(&:ticker)
    assert_equal %w[CCC BBB AAA], @statement.holdings_table_rows(sort: "return", dir: "asc").map(&:ticker)
    assert_equal %w[CCC AAA BBB], @statement.holdings_table_rows(sort: "drop table", dir: "sideways").map(&:ticker), "unknown keys fall back to the default"
  end

  test "holdings_table_rows issues no query per holding" do
    account = create_investment_account(balance: 10_000)
    5.times do |i|
      security = Security.create!(ticker: "S#{i}", name: "Security #{i}")
      Holding.create!(account: account, security: security, date: 1.day.ago.to_date, qty: 1, price: 90, amount: 90, currency: "USD")
      Holding.create!(account: account, security: security, date: Date.current, qty: 1, price: 100, amount: 100, currency: "USD", cost_basis: 80)
    end
    @statement.current_holdings.to_a

    queries = capture_sql_queries { @statement.holdings_table_rows(sort: "day_change", dir: "desc") }

    assert_equal 1, queries.grep(/FROM "holdings"/).size, "only the previous-snapshot query may run"
    assert_empty queries.grep(/FROM "trades"|FROM "security_prices"/), "no cost-basis fallback or price lookups per row"
  end

  test "allocation_by groups the portfolio by account, currency and kind with weights summing to 100" do
    usd = create_investment_account(balance: 3000, cash_balance: 1000, currency: "USD")
    eur = create_investment_account(balance: 2000, cash_balance: -50, currency: "EUR")
    ExchangeRate.create!(from_currency: "EUR", to_currency: "USD", date: Date.current, rate: 1.1)
    stock = Security.create!(ticker: "AAPL", name: "Apple")
    coin = Security.create!(ticker: "BTCUSD", name: "Bitcoin", exchange_operating_mic: Provider::BinancePublic::BINANCE_MIC)
    cash_security = Security.cash_for(eur)

    Holding.create!(account: usd, security: stock, date: Date.current, qty: 10, price: 100, amount: 1000, currency: "USD")
    Holding.create!(account: usd, security: coin, date: Date.current, qty: 1, price: 1000, amount: 1000, currency: "USD")
    Holding.create!(account: eur, security: stock, date: Date.current, qty: 5, price: 200, amount: 1000, currency: "EUR")
    Holding.create!(account: eur, security: cash_security, date: Date.current, qty: 500, price: 1, amount: 500, currency: "EUR")

    by_account = @statement.allocation_by(:account)
    assert_equal [ usd.id, eur.id ].map(&:to_s), by_account.map(&:id)
    assert_equal Money.new(3000, "USD"), by_account.first.amount
    assert_in_delta 100.0, by_account.sum(&:weight), 0.01

    by_currency = @statement.allocation_by("currency")
    # USD: 1000 + 1000 holdings + 1000 cash = 3000; EUR: (1000 + 500) * 1.1 = 1650; negative EUR cash is omitted.
    assert_equal %w[USD EUR], by_currency.map(&:id)
    assert_equal Money.new(3000, "USD"), by_currency.first.amount
    assert_in_delta 1650, by_currency.last.amount.amount, 0.001
    assert_in_delta 100.0, by_currency.sum(&:weight), 0.01

    by_kind = @statement.allocation_by(:kind)
    # standard: 1000 + 1100; cash: 1000 + 550; crypto: 1000
    assert_equal %w[standard cash crypto], by_kind.map(&:id)
    assert_in_delta 2100, by_kind.first.amount.amount, 0.001
    assert_in_delta 1550, by_kind.second.amount.amount, 0.001
    assert_in_delta 100.0, by_kind.sum(&:weight), 0.01

    by_security = @statement.allocation_by("nonsense")
    assert_equal "cash", by_security.last.id, "an unknown grouping is the security roll-up, cash row included"
    assert_in_delta 100.0, by_security.sum(&:weight), 0.01
  end

  test "every allocation grouping measures the same portfolio" do
    # One account holding securities plus cash, one all-cash: the shape the
    # groupings could disagree on, since account grouping reads balances and
    # currency and kind read holdings plus each account's cash.
    mixed = create_investment_account(balance: 10_000, cash_balance: 2_000)
    create_investment_account(balance: 3_000, cash_balance: 3_000)
    security = create_portfolio_security
    Holding.create!(account: mixed, security: security, date: Date.current, qty: 80, price: 100, amount: 8_000, currency: "USD")

    totals = InvestmentStatement::ALLOCATION_GROUPINGS.to_h do |by|
      segments = @statement.allocation_by(by)
      assert_in_delta 100.0, segments.sum(&:weight), 0.01, "#{by} weights must sum to 100"
      [ by, segments.sum { |segment| segment.amount.amount } ]
    end

    assert_equal [ @statement.portfolio_value ], totals.values.uniq,
      "every grouping must add up to the portfolio value: #{totals.inspect}"
  end

  test "data_quality_issues flags missing cost basis, stale prices and unhealthy providers" do
    account = create_investment_account(balance: 5000)
    as_of = Date.current
    fresh = Security.create!(ticker: "FRESH", name: "Fresh")
    stale = Security.create!(ticker: "STALE", name: "Stale")
    unpriced = Security.create!(ticker: "NOPX", name: "Unpriced")
    offline = Security.create!(ticker: "OFFL", name: "Offline", offline: true)
    cash = Security.cash_for(account)

    Security::Price.create!(security: fresh, date: as_of - 2.days, price: 10, currency: "USD")
    Security::Price.create!(security: stale, date: as_of - 6.days, price: 10, currency: "USD")
    Security::Price.create!(security: offline, date: as_of, price: 10, currency: "USD")

    # fresh: stored basis. stale: no stored basis but a buy trade computes one.
    # unpriced: nothing. moved: a buy plus a Transfer, which makes the cost
    # unknown by Holding#calculate_avg_cost's rule.
    moved = Security.create!(ticker: "MOVED", name: "Moved in")
    Security::Price.create!(security: moved, date: as_of, price: 10, currency: "USD")
    Holding.create!(account: account, security: fresh, date: as_of, qty: 1, price: 10, amount: 10, currency: "USD", cost_basis: 8, cost_basis_locked: true)
    Holding.create!(account: account, security: stale, date: as_of, qty: 1, price: 10, amount: 10, currency: "USD")
    create_portfolio_trade(account: account, security: stale, qty: 1, price: 9, date: as_of - 10.days)
    Holding.create!(account: account, security: unpriced, date: as_of, qty: 1, price: 10, amount: 10, currency: "USD")
    Holding.create!(account: account, security: moved, date: as_of, qty: 2, price: 10, amount: 20, currency: "USD")
    create_portfolio_trade(account: account, security: moved, qty: 1, price: 9, date: as_of - 10.days)
    create_portfolio_trade(account: account, security: moved, qty: 1, price: 9, date: as_of - 9.days, label: "Transfer")
    Holding.create!(account: account, security: offline, date: as_of, qty: 1, price: 10, amount: 10, currency: "USD", cost_basis: 8, cost_basis_locked: true)
    Holding.create!(account: account, security: cash, date: as_of, qty: 100, price: 1, amount: 100, currency: "USD")

    issues = @statement.data_quality_issues(as_of: as_of)
    by_kind = issues.group_by(&:kind).transform_values { |list| list.map { |i| i.security.ticker } }

    assert_equal %w[MOVED NOPX], by_kind[:missing_cost_basis],
      "a buy trade means the basis is computable (STALE is not flagged); a Transfer makes it unknown (MOVED is)"
    assert_equal %w[NOPX STALE], by_kind[:stale_price]
    assert_includes by_kind[:provider], "OFFL"
    assert_not_includes issues.map { |i| i.security.ticker }, cash.ticker
    assert_equal as_of - 6.days, issues.find { |i| i.kind == :stale_price && i.security == stale }.detail
    assert_equal :offline, issues.find { |i| i.kind == :provider && i.security == offline }.detail
  end

  test "data_quality_issues issues a bounded number of queries" do
    account = create_investment_account(balance: 5000)
    6.times do |i|
      security = Security.create!(ticker: "Q#{i}", name: "Q #{i}")
      Holding.create!(account: account, security: security, date: Date.current, qty: 1, price: 10, amount: 10, currency: "USD")
    end
    @statement.current_holdings.to_a

    queries = capture_sql_queries { @statement.data_quality_issues(as_of: Date.current) }
    assert_operator queries.size, :<=, 3, "expected the cost-basis preload and latest prices queries only, got:\n#{queries.join("\n")}"
  end

  test "average costs are preloaded in one query and agree with Holding#calculate_avg_cost" do
    account = create_investment_account(balance: 10_000, currency: "USD")
    plain = create_portfolio_security
    fx = create_portfolio_security
    transferred = create_portfolio_security
    unlabelled = create_portfolio_security
    tradeless = create_portfolio_security
    future_only = create_portfolio_security
    ExchangeRate.create!(from_currency: "EUR", to_currency: "USD", date: 10.days.ago.to_date, rate: 1.2)

    create_portfolio_trade(account: account, security: plain, qty: 10, price: 100, date: 10.days.ago.to_date)
    create_portfolio_trade(account: account, security: plain, qty: 10, price: 120, date: 5.days.ago.to_date)
    create_portfolio_trade(account: account, security: plain, qty: -5, price: 130, date: 3.days.ago.to_date)
    # A EUR trade in a USD account: converted at the trade date's rate.
    account.entries.create!(name: "EUR buy", date: 10.days.ago.to_date, amount: 500, currency: "EUR", entryable: Trade.new(qty: 5, price: 100, fee: 0, currency: "EUR", security: fx, investment_activity_label: "Buy"))
    create_portfolio_trade(account: account, security: transferred, qty: 4, price: 50, date: 8.days.ago.to_date)
    create_portfolio_trade(account: account, security: transferred, qty: 4, price: 60, date: 6.days.ago.to_date, label: "Transfer")
    create_portfolio_trade(account: account, security: unlabelled, qty: 2, price: 30, date: 9.days.ago.to_date).entryable.update!(investment_activity_label: nil)
    create_portfolio_trade(account: account, security: future_only, qty: 1, price: 999, date: Date.current)

    [ plain, fx, transferred, unlabelled, tradeless, future_only ].each do |security|
      Holding.create!(account: account, security: security, date: 1.day.ago.to_date, qty: 1, price: 100, amount: 100, currency: "USD")
    end

    holdings = nil
    queries = capture_sql_queries { holdings = @statement.holdings_with_avg_costs }
    assert_equal 1, queries.grep(/FROM "trades"|JOIN trades/).size, "the fallback must be one query for every holding"

    holdings.each do |holding|
      expected = Holding.find(holding.id).send(:calculate_avg_cost)
      actual = holding.avg_cost
      if expected.nil?
        assert_nil actual, holding.security.ticker
      else
        assert_in_delta expected.amount, actual.amount, 0.0001, holding.security.ticker
        assert_equal expected.currency, actual.currency
      end
    end

    by_ticker = holdings.index_by { |h| h.security.ticker }
    assert_in_delta 110, by_ticker[plain.ticker].avg_cost.amount, 0.0001
    assert_in_delta 120, by_ticker[fx.ticker].avg_cost.amount, 0.0001
    assert_nil by_ticker[transferred.ticker].avg_cost, "a transfer makes the position's cost unknown"
    assert_in_delta 30, by_ticker[unlabelled.ticker].avg_cost.amount, 0.0001
    assert_nil by_ticker[tradeless.ticker].avg_cost
    assert_nil by_ticker[future_only.ticker].avg_cost, "a trade after the holding date does not count"

    # The KPI readers use the preloaded answers: no trades query of their own.
    kpi_queries = capture_sql_queries { @statement.unrealized_gains; @statement.unrealized_gains_trend; @statement.top_holdings(limit: 5) }
    assert_empty kpi_queries.grep(/FROM "trades"|JOIN trades/)
  end

  private
    def create_investment_account(balance:, cash_balance: 0, currency: "USD")
      @family.accounts.create!(
        name: "Investment #{SecureRandom.hex(3)}",
        balance: balance,
        cash_balance: cash_balance,
        currency: currency,
        accountable: Investment.new
      )
    end

    # end_balance is a stored virtual column; with no flows, start_non_cash_balance
    # drives it (matching the period_return_trend tests above).
    def create_balance(account, date:, amount:, currency: "USD")
      account.balances.create!(
        date: date,
        balance: amount,
        currency: currency,
        start_non_cash_balance: amount
      )
    end


    def create_trade(account:, qty:, amount:, date:)
      account.entries.create!(
        name: "Trade #{SecureRandom.hex(3)}",
        amount: amount,
        date: date,
        currency: account.currency,
        entryable: Trade.new(
          security: Security.create!(ticker: "T#{SecureRandom.hex(8)}", name: "Test Security"),
          qty: qty,
          price: amount.to_d.abs / qty.to_d.abs,
          currency: account.currency
        )
      )
    end
end
