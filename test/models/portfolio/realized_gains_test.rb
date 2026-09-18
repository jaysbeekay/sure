require "test_helper"

class Portfolio::RealizedGainsTest < ActiveSupport::TestCase
  include PortfolioReturnsTestHelper
  include SqlQueryCapture

  setup do
    @family = families(:empty)
    @account = create_portfolio_account(family: @family)
    @march = Date.new(2026, 3, 10)
    @april = Date.new(2026, 4, 14)
    @period = Period.custom(start_date: Date.new(2026, 1, 1), end_date: Date.new(2026, 12, 31))
  end

  # The base case, hand-computable: 2 shares bought at an average of 100, sold
  # at 150, is 300 out against 200 of basis. The second disposal is a month
  # later so the buckets have to separate rather than merge into one total.
  test "a sale is bucketed in the month it was crystallised" do
    holding_snapshot account: @account, date: @march, qty: 5, price: 150, cost_basis: 100
    sell_trade account: @account, date: @march, qty: 2, price: 150
    sell_trade account: @account, date: @april, qty: 1, price: 130

    buckets = realized.buckets

    assert_equal [ Date.new(2026, 3, 1), Date.new(2026, 4, 1) ], buckets.map(&:month)
    assert_equal BigDecimal(100), buckets.first.gains
    assert_equal BigDecimal(0), buckets.first.losses
    assert_equal BigDecimal(30), buckets.second.gains
    assert_equal BigDecimal(130), realized.net
    assert_equal 2, realized.trade_count
  end

  # A transfer out carries the same negative qty as a sale, so a bare `qty < 0`
  # filter books the whole market value of a position the user simply moved.
  # Nothing was disposed of, so there is no month and no figure -- not a zero.
  test "a transfer out is not a realised sale" do
    holding_snapshot account: @account, date: @march, qty: 5, price: 150, cost_basis: 100
    security_journal account: @account, date: @march, qty: -2

    assert_empty realized.buckets
    assert_equal BigDecimal(0), realized.net
    assert_equal 0, realized.trade_count
    assert_empty realized.excluded_trades,
                 "a movement that realised nothing is not a disposal this class failed to measure"
  end

  # A realised gain is locked at the moment of sale. Today's rate is deliberately
  # different and much larger: if it were used, the figure would be 300, not 150.
  test "a foreign currency sale converts at its own trade date" do
    account = create_portfolio_account(family: @family, currency: "EUR")
    holding_snapshot account: account, date: @march, qty: 5, price: 150, cost_basis: 100
    sell_trade account: account, date: @march, qty: 2, price: 150
    set_rate from: "EUR", to: "USD", date: @march, rate: 1.5
    set_rate from: "EUR", to: "USD", date: Date.current, rate: 3.0

    gains = Portfolio::RealizedGains.new(accounts: [ account ], period: @period, currency: "USD")

    assert_equal BigDecimal(150), gains.net, "100 EUR of gain at the trade date's 1.5, not today's 3.0"
  end

  # No parity fallback: the #121 readiness review settled that for the whole
  # engine. A rate that is not held makes the trade unmeasurable, and an
  # unmeasurable trade is reported, never counted at 1:1.
  test "a sale with no exchange rate for its trade date is excluded and counted" do
    account = create_portfolio_account(family: @family, currency: "EUR")
    holding_snapshot account: account, date: @march, qty: 5, price: 150, cost_basis: 100
    sell_trade account: account, date: @march, qty: 2, price: 150

    gains = Portfolio::RealizedGains.new(accounts: [ account ], period: @period, currency: "USD")

    assert_empty gains.buckets
    assert_equal({ missing_exchange_rate: 1 }, gains.excluded_trades)
    assert_equal 1, gains.excluded_trade_count
  end

  # ReportsController#build_investment_metrics folds this case to 0, which drags
  # a total toward zero with nothing on the page saying so.
  test "a sale with no determinable cost basis is excluded and counted" do
    holding_snapshot account: @account, date: @march, qty: 5, price: 150, cost_basis: nil
    sell_trade account: @account, date: @march, qty: 2, price: 150

    assert_empty realized.buckets
    assert_equal BigDecimal(0), realized.net
    assert_equal({ missing_cost_basis: 1 }, realized.excluded_trades)
  end

  # The section is gated on #any?. A period whose every disposal was
  # unmeasurable has no buckets, so gating on buckets alone hid the one thing
  # the user needed to see -- that the page is missing data. Reporting the
  # exclusions and then hiding the report is worse than not reporting them.
  test "a period whose only disposals are all excluded still reports itself" do
    holding_snapshot account: @account, date: @march, qty: 5, price: 150, cost_basis: nil
    sell_trade account: @account, date: @march, qty: 2, price: 150

    assert_empty realized.buckets
    assert realized.any?, "the section must render to surface the exclusion"
    assert_equal({ missing_cost_basis: 1 }, realized.excluded_trades)
  end

  test "a portfolio with no disposals at all reports nothing" do
    assert_not realized.any?
    assert_empty realized.excluded_trades
  end

  # `losses` is a positive magnitude and `net` carries the sign, so a losing
  # month is not silently absorbed into a smaller gain.
  test "a disposal below cost is a loss, reported as a magnitude with a negative net" do
    holding_snapshot account: @account, date: @march, qty: 5, price: 60, cost_basis: 100
    sell_trade account: @account, date: @march, qty: 2, price: 60

    bucket = realized.buckets.sole

    assert_equal BigDecimal(0), bucket.gains
    assert_equal BigDecimal(80), bucket.losses, "reported as a magnitude, as Drivers#fees is"
    assert_equal BigDecimal(-80), bucket.net
    assert_equal BigDecimal(-80), realized.net
  end

  # Both sides of the same month, so the two series are exercised together
  # rather than one bucket only ever holding one of them.
  test "gains and losses in one month are reported separately" do
    other = create_portfolio_security_for_loss
    holding_snapshot account: @account, date: @march, qty: 5, price: 150, cost_basis: 100
    holding_snapshot account: @account, date: @march, qty: 5, price: 60, cost_basis: 100, security: other
    sell_trade account: @account, date: @march, qty: 2, price: 150
    sell_trade account: @account, date: @march, qty: 1, price: 60, security: other

    bucket = realized.buckets.sole

    assert_equal BigDecimal(100), bucket.gains
    assert_equal BigDecimal(40), bucket.losses
    assert_equal BigDecimal(60), bucket.net
    assert_equal 2, bucket.trade_count
  end

  # Trade#realized_gain_loss falls back to its own holdings query per trade
  # unless one is handed to it, so without the preload the query count grows
  # with the number of disposals. Asserting equality rather than a magic
  # number: the constant is the claim, and a number would only pin today's.
  test "the query count does not grow with the number of disposals" do
    holding_snapshot account: @account, date: @march, qty: 20, price: 150, cost_basis: 100
    2.times { sell_trade account: @account, date: @march, qty: 1, price: 150 }
    few = capture_sql_queries { measure_fully(build_gains) }.size

    4.times { sell_trade account: @account, date: @march, qty: 1, price: 150 }
    many = capture_sql_queries { measure_fully(build_gains) }.size

    assert_equal 6, build_gains.trade_count, "the fixture must actually grow, or this proves nothing"
    assert_equal few, many, "2 disposals and 6 must cost the same number of queries"
  end

  # The test above seeds a stored cost_basis, which is the path that never
  # falls back. A provider-synced holding commonly carries nil, and then
  # Holding#avg_cost runs #calculate_avg_cost -- account, security, exists?
  # and pick. Those repeat per distinct security, not per disposal, so the
  # fixture has to vary the security or it measures nothing: before
  # Holding.preload_avg_costs was wired in, this read 9 queries against 21.
  test "the query count does not grow with disposals against holdings with no stored basis" do
    seed_unpriced_disposals(2)
    few = capture_sql_queries { measure_fully(build_gains) }.size

    seed_unpriced_disposals(4)
    many = capture_sql_queries { measure_fully(build_gains) }.size

    assert_equal 6, build_gains.trade_count, "the fixture must actually grow, or this proves nothing"
    assert_equal BigDecimal(300), build_gains.net, "and the basis must still be computed, not skipped"
    assert_equal few, many, "2 disposals over 2 securities and 6 over 6 must cost the same"
  end

  # The conversion the disposals need is a rate lookup, and one per foreign
  # disposal would be a new N+1 introduced by the very fix that made them
  # measurable. Trade.preload_exchange_rates answers all of them in one query.
  #
  # Each disposal falls on its OWN date, which is what makes this measure
  # anything: identical lookups are served by the ActiveRecord query cache, so
  # a fixture with every sale on one day reads as flat whether the preload runs
  # or not. I wrote that version first and watched the mutation pass it.
  test "the query count does not grow with the number of cross-currency disposals" do
    holding_snapshot account: @account, date: @march, qty: 20, price: 150, cost_basis: 100
    seed_foreign_disposals(2)
    few = capture_sql_queries { measure_fully(build_gains) }.size

    seed_foreign_disposals(4, offset: 2)
    many = capture_sql_queries { measure_fully(build_gains) }.size

    assert_equal 6, build_gains.trade_count, "the fixture must actually grow, or this proves nothing"
    assert_equal BigDecimal(750), build_gains.net, "and every disposal must still be measured"
    assert_equal few, many, "2 foreign disposals over 2 dates and 6 over 6 must cost the same"
  end

  # The flat-count test above seeds USD-basis holdings, so both conversion legs
  # are covered by a batch and it cannot see this: when the POSITION is carried
  # in a third currency, the statement leg is GBP->USD, GBP is in neither set
  # the hub enumerates, and every disposal pays its own `find_by`. That is the
  # exact shape the Trade-side preload was extended to cover, one level up.
  #
  # Each disposal falls on its own date, or the ActiveRecord query cache serves
  # the repeats and the fixture reads flat whether the batch covers it or not.
  test "the query count does not grow with disposals carried in a third currency" do
    seed_third_currency_disposals(2)
    few = capture_sql_queries { measure_fully(build_gains) }.size

    seed_third_currency_disposals(4, offset: 2)
    many = capture_sql_queries { measure_fully(build_gains) }.size

    assert_equal 6, build_gains.trade_count, "the fixture must actually grow, or this proves nothing"
    assert_empty build_gains.excluded_trades, "every rate these disposals need is on file"
    assert_equal BigDecimal(300), build_gains.net, "and every one of them is measured"
    assert_equal few, many, "2 third-currency disposals over 2 dates and 6 over 6 must cost the same"
  end

  # A USD account holding a EUR-listed security: basis 100 USD/share, 2 sold at
  # 150 EUR/share, EUR->USD 1.5 on the trade date. 300 EUR of proceeds is 450
  # USD, less 200 USD of basis, so 250 USD.
  #
  # This was excluded as unmeasurable until jaysbeekay/sure#169 fixed the
  # arithmetic in Trade#calculate_realized_gain_loss: `Trend#value` is
  # `current - previous` and `Money#-` neither converts nor raises, so the
  # basis was subtracted from the proceeds as a bare number and the 250 was
  # reported as 150. The proceeds are now converted into the basis's currency
  # before the subtraction, so the disposal is measured rather than declined.
  test "a disposal priced in a currency the holding is not valued in is measured" do
    holding_snapshot account: @account, date: @march, qty: 5, price: 150, cost_basis: 100
    sell_trade account: @account, date: @march, qty: 2, price: 150, currency: "EUR"
    set_rate from: "EUR", to: "USD", date: @march, rate: 1.5

    assert_empty realized.excluded_trades, "a rate for the day is all this needed"
    assert_equal BigDecimal(250), realized.net
  end

  # The rate has to be the one for the day the disposal happened. Without it
  # the proceeds cannot be expressed in the basis's currency at all, and the
  # tally must say THAT rather than blame the cost basis -- which is present,
  # and would send the user to fix something that is not broken.
  test "a cross-currency disposal with no rate for its date is excluded as a missing rate" do
    holding_snapshot account: @account, date: @march, qty: 5, price: 150, cost_basis: 100
    sell_trade account: @account, date: @march, qty: 2, price: 150, currency: "EUR"
    set_rate from: "EUR", to: "USD", date: @march - 1, rate: 1.5

    assert_empty realized.buckets
    assert_equal({ missing_exchange_rate: 1 }, realized.excluded_trades)
    assert_equal BigDecimal(0), realized.net
  end

  # The statement's own conversion leg has the same exposure as the disposal's.
  # `ExchangeRate` requires a rate to be present, not to be usable, so a 0 in
  # the GBP->USD row would carry a real 40 GBP gain into the tally as 0 USD --
  # a figure, in the net, indistinguishable from a disposal that broke even.
  # A rate that cannot convert excludes the disposal, exactly as an absent one
  # does.
  test "a statement rate that cannot convert excludes the disposal" do
    @account.holdings.create!(
      security: security_under_test, date: @march, qty: 5, price: 150,
      amount: BigDecimal(750), currency: "GBP", cost_basis: 100
    )
    sell_trade account: @account, date: @march, qty: 2, price: 150, currency: "EUR"
    set_rate from: "EUR", to: "GBP", date: @march, rate: 0.8
    set_rate from: "GBP", to: "USD", date: @march, rate: 0

    assert_empty realized.buckets, "0 is not a conversion"
    assert_equal({ missing_exchange_rate: 1 }, realized.excluded_trades)
    assert_equal BigDecimal(0), realized.net
  end

  # THREE currencies: the statement is in USD, the position is carried in GBP,
  # and the disposal was priced in EUR. 300 EUR of proceeds at 0.8 is 240 GBP,
  # less 200 GBP of basis, so 40 GBP -- and 50 USD at 1.25.
  #
  # Both batches cover it now, and neither did when it was written: Trade's rate
  # preload keyed the basis side on the ACCOUNT's currency and this section's
  # own batch enumerated the disposals' and the accounts', so GBP was in neither
  # and each leg fell back to a single lookup. Both key on the holding's
  # currency as well; what this test pins is unchanged either way -- a disposal
  # with every rate it needs on file is measured, not tallied as a missing rate.
  test "a disposal is measured when the basis, the disposal and the statement are three currencies" do
    @account.holdings.create!(
      security: security_under_test, date: @march, qty: 5, price: 150,
      amount: BigDecimal(750), currency: "GBP", cost_basis: 100
    )
    sell_trade account: @account, date: @march, qty: 2, price: 150, currency: "EUR"
    set_rate from: "EUR", to: "GBP", date: @march, rate: 0.8
    set_rate from: "GBP", to: "USD", date: @march, rate: 1.25

    assert_empty realized.excluded_trades, "every rate this disposal needs is on file"
    assert_equal BigDecimal(50), realized.net
  end

  # An account, holding and disposal all in EUR measure and convert once, at
  # the statement's currency.
  test "a wholly foreign disposal is still measured when its holding agrees" do
    account = create_portfolio_account(family: @family, currency: "EUR")
    holding_snapshot account: account, date: @march, qty: 5, price: 150, cost_basis: 100
    sell_trade account: account, date: @march, qty: 2, price: 150
    set_rate from: "EUR", to: "USD", date: @march, rate: 1.5

    gains = Portfolio::RealizedGains.new(accounts: [ account ], period: @period, currency: "USD")

    assert_empty gains.excluded_trades, "matching currencies are not a mismatch"
    assert_equal BigDecimal(150), gains.net
  end

  # A disabled account stops contributing on its cut-off date, exactly as it
  # stops contributing to the value chart and to the daily returns.
  test "a disposal after an account's cut-off date does not count" do
    holding_snapshot account: @account, date: @march, qty: 5, price: 150, cost_basis: 100
    sell_trade account: @account, date: @april, qty: 2, price: 150

    gains = Portfolio::RealizedGains.new(
      accounts: [ @account ],
      period: @period,
      currency: "USD",
      active_until_dates: { @account.id => @march }
    )

    assert_empty gains.buckets
  end

  test "a disposal outside the period does not count" do
    holding_snapshot account: @account, date: @march, qty: 5, price: 150, cost_basis: 100
    sell_trade account: @account, date: Date.new(2025, 11, 4), qty: 2, price: 150

    assert_empty realized.buckets
  end

  private
    def realized
      build_gains
    end

    def build_gains
      Portfolio::RealizedGains.new(accounts: [ @account ], period: @period, currency: "USD")
    end

    # Reads every derived figure, so the capture covers the whole query path
    # rather than stopping at the first memoised one.
    def measure_fully(gains)
      gains.buckets
      gains.excluded_trades
      gains.net
    end

    # n EUR-priced disposals, each on its own date with its own rate row, so
    # every one needs a DISTINCT rate lookup and the query cache cannot hide a
    # per-disposal query behind the first one.
    def seed_foreign_disposals(count, offset: 0)
      count.times do |i|
        date = @march + offset + i
        set_rate from: "EUR", to: "USD", date: date, rate: 1.5
        sell_trade account: @account, date: date, qty: 1, price: 150, currency: "EUR"
      end
    end

    # A GBP-carried position under a USD statement, sold in EUR: three
    # currencies, one date each, and both rates on file for every date. 300 EUR
    # of proceeds at 0.8 is 240 GBP, less 200 GBP of basis, so 40 GBP and 50 USD
    # at 1.25 -- per disposal, at qty 2.
    def seed_third_currency_disposals(count, offset: 0)
      count.times do |i|
        date = @march + offset + i
        @account.holdings.create!(
          security: security_under_test, date: date, qty: 20, price: 150,
          amount: BigDecimal(3_000), currency: "GBP", cost_basis: 100
        )
        set_rate from: "EUR", to: "GBP", date: date, rate: 0.8
        set_rate from: "GBP", to: "USD", date: date, rate: 1.25
        sell_trade account: @account, date: date, qty: 2, price: 150, currency: "EUR"
      end
    end

    # n securities, each with a nil-basis snapshot, a buy at 100 and one sale
    # at 150 -- so every disposal needs the trade-derived basis, and each needs
    # its own row in it.
    def seed_unpriced_disposals(count)
      count.times do |i|
        security = Security.create!(ticker: "RG#{i}#{SecureRandom.hex(4)}", name: "Unpriced #{i}")
        @account.holdings.create!(
          security: security, date: @march, qty: 20, price: 150,
          amount: BigDecimal(3_000), currency: @account.currency, cost_basis: nil
        )
        @account.entries.create!(
          name: "Buy", date: Date.new(2026, 1, 8), amount: BigDecimal(2_000), currency: @account.currency,
          entryable: Trade.new(security: security, qty: 20, price: 100,
                               currency: @account.currency, investment_activity_label: "Buy")
        )
        sell_trade account: @account, date: @march, qty: 1, price: 150, security: security
      end
    end

    def create_portfolio_security_for_loss
      Security.create!(ticker: "LOSS#{SecureRandom.hex(4)}", name: "Loss Security")
    end
end
