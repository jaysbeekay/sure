require "test_helper"

class Portfolio::PerformanceTest < ActiveSupport::TestCase
  include PortfolioReturnsTestHelper

  setup do
    @family = families(:empty) # USD
    @account = create_portfolio_account(family: @family)
    @day_one = Date.new(2026, 3, 2)
    @day_two = Date.new(2026, 3, 3)
  end

  # Contract R3. The textbook case, worked by hand:
  #
  #   sub-period 1: 1,000 grows to 1,100                  -> 1.10
  #   1,000 is then deposited, so 1,100 becomes 2,100
  #   sub-period 2: 2,100 grows to 2,310                  -> 1.10
  #   chained: 1.10 x 1.10 - 1                            = 21.0%
  #
  # The deposit must not appear as performance. A method that let it through
  # would report 131% for a portfolio that returned 21%.
  test "twr matches the hand computed textbook case" do
    build_textbook_case

    assert_in_delta 0.21, performance.twr.to_f, 0.000001
  end

  # Contract R4. Two days of history annualised is a number with no meaning:
  # a 21% fortnight compounds to something absurd, and printing it would be
  # presenting an artefact of the arithmetic as a fact about the portfolio.
  test "annualized twr is nil for periods under a year" do
    build_textbook_case

    assert_not_nil performance.twr
    assert_nil performance.annualized_twr
  end

  # Contract R5. Daily returns of +10%, -10%, 0 have a sample standard deviation
  # of 0.1 exactly (mean 0, variance (0.01 + 0.01 + 0) / 2). Annualising a
  # CALENDAR-daily series uses sqrt(365), not the trading-day sqrt(252): the
  # balance rows include weekends, so a third of the series is structural zeros
  # and the trading-day convention would overstate the result by about 19%.
  test "volatility annualises calendar daily returns by sqrt 365" do
    day_three = @day_two + 1.day
    lay_balance account: @account, date: @day_one, opening: 1_000, closing: 1_100, market_flow: 100
    lay_balance account: @account, date: @day_two, opening: 1_100, closing: 990, market_flow: -110
    lay_balance account: @account, date: day_three, opening: 990, closing: 990

    result = performance(end_date: day_three)

    expected = 0.1 * Math.sqrt(365)
    assert_in_delta expected, result.volatility.to_f, 0.0001
    refute_in_delta 0.1 * Math.sqrt(252), result.volatility.to_f, 0.01,
                    "the trading-day convention does not fit a calendar-daily series"
  end

  # Contract R8. Same portfolio, two questions. TWR asks how the holdings did;
  # MWR asks how the investor did, and rewards or punishes the timing of their
  # own contributions. Averaging or substituting one for the other is the error
  # this row exists to prevent.
  test "mwr differs from twr when flows are unevenly timed" do
    start_date = Date.new(2026, 1, 1)
    mid_date = Date.new(2026, 7, 2)
    end_date = Date.new(2026, 12, 31)

    lay_balance account: @account, date: start_date, opening: 1_000, closing: 1_000
    lay_balance account: @account, date: mid_date, opening: 1_000, closing: 2_000, cash_flow: 1_000
    lay_balance account: @account, date: end_date, opening: 2_000, closing: 2_200, market_flow: 200
    deposit account: @account, date: mid_date, amount: 1_000

    result = performance(start_date: start_date, end_date: end_date)

    # All of the growth lands in the final sub-period: 2,000 -> 2,200.
    assert_in_delta 0.10, result.twr.to_f, 0.000001

    # The investor had 1,000 committed for the year and 1,000 for half of it,
    # so the same 200 of gain is earned on less capital: about 13.5%.
    assert_in_delta 0.1346, result.mwr.to_f, 0.002
    refute_equal result.twr, result.mwr
  end

  # Contract R14. This is the defect the issue's proposed cache key would have
  # shipped. `entries_cache_version` counts entries and their timestamps; a
  # daily price sync rewrites holdings and balances and touches no entry, so a
  # figure cached on it stays stale until the user happens to edit a
  # transaction.
  test "cache key changes when a price sync completes without touching entries" do
    build_textbook_case

    before_key = performance.cache_key
    before_entries_version = @family.entries_cache_version

    @family.update!(latest_sync_completed_at: 1.hour.from_now)
    @family.reload

    assert_equal before_entries_version, @family.entries_cache_version,
                 "the fixture must not touch entries, or this proves nothing"
    refute_equal before_key, Portfolio::Performance.new(
      family: @family, account_ids: [ @account.id ],
      period: Period.custom(start_date: @day_one, end_date: @day_two)
    ).cache_key
  end

  test "annualized twr is reported for a period of a year or more" do
    start_date = Date.new(2026, 1, 1)
    end_date = Date.new(2026, 12, 31)

    lay_balance account: @account, date: start_date, opening: 1_000, closing: 1_000
    lay_balance account: @account, date: end_date, opening: 1_000, closing: 1_100, market_flow: 100

    result = performance(start_date: start_date, end_date: end_date)

    assert_in_delta 0.10, result.twr.to_f, 0.000001
    assert_in_delta 0.10, result.annualized_twr.to_f, 0.001,
                    "a 10% year annualises to 10%"
  end

  test "max drawdown measures the largest peak to trough fall" do
    day_three = @day_two + 1.day
    lay_balance account: @account, date: @day_one, opening: 1_000, closing: 1_200, market_flow: 200
    lay_balance account: @account, date: @day_two, opening: 1_200, closing: 900, market_flow: -300
    lay_balance account: @account, date: day_three, opening: 900, closing: 1_000, market_flow: 100

    result = performance(end_date: day_three)

    # The index peaks at 1.20 and falls to 0.90: a 25% drawdown.
    assert_in_delta 0.25, result.max_drawdown.to_f, 0.000001
  end

  # The name matters: the series is rebased ON a base of 100, and its first point
  # is the level AFTER the first return. There is no 100 in the output, which is
  # why the assertions below start at 110.
  test "the index series is rebased on a base of one hundred and starts after the first return" do
    build_textbook_case

    series = performance.index_series

    assert_equal 2, series.size
    assert_in_delta 110.0, series.first.last.to_f, 0.000001
    assert_in_delta 121.0, series.last.last.to_f, 0.000001
    refute_in_delta 100.0, series.first.last.to_f, 0.000001,
                    "the base itself is not a point in the series"
  end

  # R13 carried through to the metric surface: a figure that could not be
  # converted is withheld, not approximated.
  test "every ratio is withheld when an exchange rate is missing" do
    eur = create_portfolio_account(family: @family, currency: "EUR")
    lay_balance account: eur, date: @day_one, opening: 1_000, closing: 1_000
    lay_balance account: eur, date: @day_two, opening: 1_000, closing: 1_100, market_flow: 100

    result = performance(account_ids: [ eur.id ])

    assert result.rate_missing?
    assert_nil result.twr
    assert_nil result.mwr
    assert_nil result.volatility
    assert_nil result.max_drawdown
    assert_empty result.index_series
  end

  # Regression: the key was built from family, user, accounts and period only,
  # so two instances whose rows genuinely differ shared one cache entry and
  # whichever ran first decided what both saw.
  test "cache key distinguishes different account cut off dates" do
    build_textbook_case
    period = Period.custom(start_date: @day_one, end_date: @day_two)

    without_cutoff = Portfolio::Performance.new(
      family: @family, account_ids: [ @account.id ], period: period
    )
    with_cutoff = Portfolio::Performance.new(
      family: @family, account_ids: [ @account.id ], period: period,
      active_until_dates: { @account.id => @day_one }
    )

    refute_equal without_cutoff.daily_returns.rows.last.value_close,
                 with_cutoff.daily_returns.rows.last.value_close,
                 "the fixture must produce different data, or this proves nothing"
    refute_equal without_cutoff.cache_key, with_cutoff.cache_key
  end

  test "cache key distinguishes different flow scopes" do
    build_textbook_case
    period = Period.custom(start_date: @day_one, end_date: @day_two)
    other = create_portfolio_account(family: @family)

    narrow = Portfolio::Performance.new(
      family: @family, account_ids: [ @account.id ], period: period
    )
    wide = Portfolio::Performance.new(
      family: @family, account_ids: [ @account.id ], period: period,
      scope_account_ids: [ @account.id, other.id ]
    )

    refute_equal narrow.cache_key, wide.cache_key
  end

  test "an empty scope reports nothing rather than raising" do
    result = performance(account_ids: [])

    refute result.any?
    assert_nil result.twr
  end

  # R16 at the scope level. The account's value moved by revaluation only, so
  # nothing records what was paid in. Over a year an XIRR of its opening and
  # closing values solves to 20%, a figure the records do not support.
  test "mwr is withheld when an account in the scope is valuation tracked" do
    start_date = Date.new(2026, 1, 1)
    end_date = Date.new(2026, 12, 31)
    lay_balance account: @account, date: start_date, opening: 1_000, closing: 1_000
    lay_balance account: @account, date: end_date, opening: 1_000, closing: 1_200, revaluation: 200

    result = performance(start_date: start_date, end_date: end_date)

    assert_in_delta 0.20, result.twr.to_f, 0.000001, "the value return is still reportable"
    assert_nil result.mwr
  end

  # The gate must not overreach: an account with no balances in the period
  # contributes nothing, so it cannot make the scope's flows unknown.
  test "an account with no balances in the period does not withhold mwr" do
    start_date = Date.new(2026, 1, 1)
    mid_date = Date.new(2026, 7, 2)
    end_date = Date.new(2026, 12, 31)
    lay_balance account: @account, date: start_date, opening: 1_000, closing: 1_000
    lay_balance account: @account, date: mid_date, opening: 1_000, closing: 2_000, cash_flow: 1_000
    lay_balance account: @account, date: end_date, opening: 2_000, closing: 2_200, market_flow: 200
    deposit account: @account, date: mid_date, amount: 1_000
    empty = create_portfolio_account(family: @family)

    result = performance(account_ids: [ @account.id, empty.id ], start_date: start_date, end_date: end_date)

    assert_in_delta 0.1346, result.mwr.to_f, 0.002
  end

  # A single day: the opening and closing values fall on the same date, so no
  # time passes and no annual rate exists. Newton would otherwise return its
  # 10% starting guess as the answer.
  test "a one day period has no money weighted return" do
    lay_balance account: @account, date: @day_one, opening: 1_000, closing: 1_000
    buy_trade account: @account, date: @day_one, qty: 1, price: 10

    result = performance(start_date: @day_one, end_date: @day_one)

    assert_nil result.mwr
  end

  # An omitted scope means "the accounts themselves"; an explicit empty scope
  # means nothing is inside, so every transfer is external. Those are different
  # figures and must not share a cache entry.
  test "cache key distinguishes an omitted flow scope from an empty one" do
    period = Period.custom(start_date: @day_one, end_date: @day_two)

    omitted = Portfolio::Performance.new(family: @family, account_ids: [ @account.id ], period: period)
    empty = Portfolio::Performance.new(family: @family, account_ids: [ @account.id ], period: period, scope_account_ids: [])
    explicit = Portfolio::Performance.new(family: @family, account_ids: [ @account.id ], period: period, scope_account_ids: [ @account.id ])

    refute_equal omitted.cache_key, empty.cache_key
    assert_equal omitted.cache_key, explicit.cache_key, "the same effective scope may share an entry"
  end

  # Regression. DailyReturns compacts active_until_dates, so `{ id => nil }` is
  # valid input meaning "no cut-off". The cache key read the RAW hash and called
  # nil.to_date on it, raising NoMethodError before any metric was computed --
  # and a cache key is on the path of every figure, so nothing would have worked.
  test "a nil cut off date is a key, not a crash" do
    period = Period.custom(start_date: @day_one, end_date: @day_two)

    nil_cutoff = Portfolio::Performance.new(
      family: @family, account_ids: [ @account.id ], period: period,
      active_until_dates: { @account.id => nil }
    )
    none = Portfolio::Performance.new(family: @family, account_ids: [ @account.id ], period: period)

    assert_equal none.cache_key, nil_cutoff.cache_key,
                 "a nil cut-off means no cut-off, so it is the same scope and may share an entry"
  end

  private
    def build_textbook_case
      lay_balance account: @account, date: @day_one, opening: 1_000, closing: 1_100, market_flow: 100
      lay_balance account: @account, date: @day_two, opening: 1_100, closing: 2_310,
                  cash_flow: 1_000, market_flow: 210
      deposit account: @account, date: @day_two, amount: 1_000
    end

    def performance(account_ids: [ @account.id ], start_date: @day_one, end_date: @day_two)
      Portfolio::Performance.new(
        family: @family,
        account_ids: account_ids,
        period: Period.custom(start_date: start_date, end_date: end_date)
      )
    end
end
