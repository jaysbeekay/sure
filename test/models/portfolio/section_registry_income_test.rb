require "test_helper"

# The income section's locals, against real balance history rather than stubs:
# what matters here is which rows reach which figure, and a stubbed
# Portfolio::Performance would assert the registry's mental model of them.
class Portfolio::SectionRegistryIncomeTest < ActiveSupport::TestCase
  include PortfolioReturnsTestHelper

  setup do
    @family = families(:empty) # USD
    @account = create_portfolio_account(family: @family)
    @as_of = Date.new(2026, 9, 15)
    @period = Period.custom(start_date: @as_of - 30, end_date: @as_of)
    @window_start = @as_of.prev_year + 1.day
  end

  # The period picker must not move the yearly figure, and the yearly figure
  # must not widen the period's. Three payouts, each in a different place:
  # before the year, inside the year but before the period, inside both.
  test "the trailing total covers the twelve months to as_of, whatever the period is" do
    pay Date.new(2025, 8, 1), 400   # a year and six weeks back: outside the window
    pay Date.new(2026, 3, 10), 200  # inside the window, outside the 30-day period
    pay @as_of - 10, 30             # inside both
    lay_history

    locals = income_locals

    assert_equal BigDecimal(30), locals[:income][:total], "the period holds one payout"
    assert_equal BigDecimal(230), locals[:trailing][:total],
                 "the year holds two: 400 is a year and six weeks old"
  end

  # Both sides of the boundary, because a window one day too wide or too narrow
  # passes any test that only looks away from the edge.
  test "the trailing window starts the day after the same date a year earlier" do
    pay @window_start - 1, 7    # the day before the window opens
    pay @window_start, 11       # its first day
    pay @as_of, 13              # its last day
    lay_history

    assert_equal BigDecimal(24), income_locals[:trailing][:total],
                 "11 and 13 are in the window, 7 is a day too old"
  end

  # Plan item: the bars and the drivers table are the same rows, so for one
  # period they have to add up to the same figure.
  test "the period's bars add up to the drivers table's income line" do
    pay @as_of - 40, 5
    pay @as_of - 20, 20
    pay @as_of - 3, 9
    lay_history
    @period = Period.custom(start_date: @as_of - 60, end_date: @as_of)

    locals = income_locals
    performance = InvestmentStatement.new(@family, user: nil).performance(period: @period)

    assert_equal BigDecimal(34), performance.drivers[:income]
    assert_equal performance.drivers[:income], locals[:bars].sum { |bar| BigDecimal(bar[:income].to_s) }
    assert_equal performance.drivers[:income], locals[:income][:total]
  end

  test "the bars carry the month, rounded income, and a zero second series" do
    pay Date.new(2026, 9, 2), BigDecimal("12.345")
    lay_history

    bars = income_locals[:bars]

    assert_equal 1, bars.size
    assert_equal Date.new(2026, 9, 1), bars.first[:date]
    assert_equal 12.35, bars.first[:income], "rounded to the cent, not 12.345000000000001"
    assert_equal 0, bars.first[:expense]
    assert_equal "Sep", bars.first[:short_label]
  end

  # The chart draws positive heights only, so a month that netted negative has
  # to travel on the other series or it vanishes and the bars stop adding up to
  # the drivers table. Reversals are rare; this is the case that was dropped.
  test "a month that netted negative is drawn on the second series, not lost" do
    pay Date.new(2026, 8, 5), 50
    pay Date.new(2026, 9, 2), -8
    lay_history
    @period = Period.custom(start_date: @as_of - 60, end_date: @as_of)

    bars = income_locals[:bars]

    assert_equal [ 50.0, 0.0 ], bars.map { |bar| bar[:income] }
    assert_equal [ 0.0, 8.0 ], bars.map { |bar| bar[:expense] }
    assert_equal income_locals[:income][:total],
                 bars.sum(BigDecimal(0)) { |bar| BigDecimal(bar[:income].to_s) - BigDecimal(bar[:expense].to_s) },
                 "income less reversals is the total the drivers table reports"
  end

  # Yield-on-cost is the issue's third exit criterion: trailing income divided
  # by cost basis. Worked by hand -- AAPL paid 15 and then 5, both inside the
  # year (the 15 outside the 30-day period), against a cost basis of 10 x 40:
  #
  #   (15 + 5) / 400 = 5%
  #
  # The table's own amount is the PERIOD's 5, so a yield computed from the amount
  # on the row (5 / 400 = 1.25%) is the mistake this separates from the right one.
  test "yield on cost is the trailing income over the cost basis, not the row's period amount" do
    aapl = securities(:aapl)
    income_trade account: @account, date: @as_of - 200, amount: 15, security: aapl
    income_trade account: @account, date: @as_of - 10, amount: 5, security: aapl
    lay_history
    holding_snapshot account: @account, date: @as_of, qty: 10, price: 50, cost_basis: 40, security: aapl

    locals = income_locals

    assert_equal [ BigDecimal(5) ], locals[:securities].rows.map(&:amount)
    assert_in_delta 0.05, locals[:yields].fetch(aapl.id.to_s).to_f, 0.0000001
  end

  # A yield over a cost basis that covers only some of the position would
  # overstate it, because the income covers all of it.
  test "yield on cost is withheld when the cost basis is unknown or the security is no longer held" do
    aapl = securities(:aapl)
    msft = securities(:msft)
    income_trade account: @account, date: @as_of - 10, amount: 5, security: aapl
    income_trade account: @account, date: @as_of - 9, amount: 6, security: msft
    lay_history
    holding_snapshot account: @account, date: @as_of, qty: 10, price: 50, cost_basis: nil, security: aapl
    # MSFT paid but is not held: sold, or never in this scope.

    yields = income_locals[:yields]

    assert_includes yields.keys, aapl.id.to_s
    assert_nil yields[aapl.id.to_s], "held without a cost basis: no yield, not a yield of zero"
    assert_includes yields.keys, msft.id.to_s
    assert_nil yields[msft.id.to_s], "not held: there is no cost basis to divide by"
  end

  # The case the guard is for. AAPL is held in two accounts and only one has a
  # cost basis, so the statement still reports a cost (the known part, 10 x 40)
  # and flags the rest as missing. The income covers BOTH positions, so dividing
  # it by that partial cost would overstate the yield.
  test "yield on cost is withheld when only some of a security's positions have a cost basis" do
    aapl = securities(:aapl)
    other = create_portfolio_account(family: @family)
    income_trade account: @account, date: @as_of - 10, amount: 5, security: aapl
    lay_history
    holding_snapshot account: @account, date: @as_of, qty: 10, price: 50, cost_basis: 40, security: aapl
    holding_snapshot account: other, date: @as_of, qty: 5, price: 50, cost_basis: nil, security: aapl

    row = InvestmentStatement.new(@family, user: nil).holdings_table_rows.find { |held| held.security == aapl }
    assert row.missing_cost_basis, "the fixture really is a partly known position"
    assert_equal BigDecimal(400), row.unrealized.previous.amount, "and its cost is still the known part"

    assert_nil income_locals[:yields].fetch(aapl.id.to_s)
  end

  # The statement values a holding with `rates[currency] || 1`, so a EUR position
  # with no rate on record is converted at parity and looks like a perfectly
  # good cost basis. Dividing by it states a yield nobody can stand behind, with
  # both income windows fully converted and nothing flagging it.
  test "yield on cost is withheld when a held position's currency has no rate" do
    aapl = securities(:aapl)
    eur = create_portfolio_account(family: @family, currency: "EUR")
    income_trade account: @account, date: @as_of - 10, amount: 5, security: aapl
    lay_history
    holding_snapshot account: eur, date: @as_of, qty: 10, price: 50, cost_basis: 40, security: aapl

    assert_nil income_locals[:yields].fetch(aapl.id.to_s), "no EUR rate: the 400 EUR cost is not 400 USD"

    set_rate from: "EUR", to: "USD", date: @as_of, rate: 2.0

    assert_not_nil income_locals[:yields].fetch(aapl.id.to_s),
                   "the control: with the rate on record the same position yields"
  end

  # A rateless currency withholds the yields it touches and no others.
  test "an unrated currency withholds only the securities held in it" do
    aapl = securities(:aapl)
    msft = securities(:msft)
    eur = create_portfolio_account(family: @family, currency: "EUR")
    income_trade account: @account, date: @as_of - 10, amount: 5, security: aapl
    income_trade account: @account, date: @as_of - 9, amount: 6, security: msft
    lay_history
    holding_snapshot account: eur, date: @as_of, qty: 10, price: 50, cost_basis: 40, security: aapl
    holding_snapshot account: @account, date: @as_of, qty: 10, price: 50, cost_basis: 40, security: msft

    yields = income_locals[:yields]

    assert_nil yields.fetch(aapl.id.to_s), "held in EUR, which has no rate"
    assert_in_delta 0.015, yields.fetch(msft.id.to_s).to_f, 0.0000001, "held in USD: 6 / 400"
  end

  # A gifted or inherited position can carry a cost basis of zero on purpose.
  # Dividing by it is not a yield of infinity; it is no yield.
  test "yield on cost is withheld, not divided by zero, when the cost basis is zero" do
    aapl = securities(:aapl)
    income_trade account: @account, date: @as_of - 10, amount: 5, security: aapl
    lay_history
    @account.holdings.create!(
      security: aapl, date: @as_of, qty: 10, price: 50, amount: 500, currency: "USD",
      cost_basis: 0, cost_basis_locked: true
    )

    yields = income_locals[:yields]

    assert_includes yields.keys, aapl.id.to_s
    assert_nil yields[aapl.id.to_s]
  end

  # Every other ratio on this page is withheld when a rate is missing (R13).
  #
  # Built from a real rateless fixture, not a stub of `rate_missing?`: a EUR
  # dividend with no EUR rate cannot be converted, which is what raises the flag,
  # and the USD security beside it still has a perfectly good yield to withhold.
  test "yield on cost is withheld when a rate is missing" do
    aapl = securities(:aapl)
    income_trade account: @account, date: @as_of - 10, amount: 5, security: aapl
    lay_history
    holding_snapshot account: @account, date: @as_of, qty: 10, price: 50, cost_basis: 40, security: aapl
    assert_not_nil income_locals[:yields][aapl.id.to_s], "the control: with every rate present, there is a yield"

    eur = create_portfolio_account(family: @family, currency: "EUR")
    income_trade account: eur, date: @as_of - 9, amount: 3, security: securities(:msft)

    locals = income_locals

    assert Portfolio::Performance.new(
      family: @family, account_ids: [ @account.id, eur.id ], period: @period
    ).rate_missing?, "the fixture really does have a missing rate"
    assert_nil locals[:yields][aapl.id.to_s], "the USD security's yield is withheld too"
  end

  # The point of the unattributed bucket, at the level a user sees it.
  test "the security table and its unattributed row add up to the period's income" do
    income_trade account: @account, date: @as_of - 10, amount: 5, security: securities(:aapl)
    income_transaction account: @account, date: @as_of - 9, amount: 7
    lay_history

    locals = income_locals

    assert_equal BigDecimal(7), locals[:securities].unattributed
    assert_equal locals[:income][:total],
                 locals[:securities].rows.sum(BigDecimal(0), &:amount) + locals[:securities].unattributed
    assert_equal BigDecimal(12), locals[:income][:total]
  end

  # R13 for the figures that cannot be withheld. Income, fees and the bars are
  # money, so they are reported whatever happens -- but an entry in a currency
  # with no rate drops out of their SQL sum, and a total that silently leaves
  # something out is the defect Realised P&L names its exclusions to avoid. The
  # section says so, for either window, because it prints both.
  test "the income section flags a missing exchange rate, and not otherwise" do
    pay @as_of - 10, 5
    lay_history

    assert_equal false, income_locals[:rate_missing], "the control: nothing foreign, so nothing missing"
  end

  test "the income section flags a missing exchange rate on a payout in the period" do
    pay @as_of - 10, 5
    lay_history
    eur = create_portfolio_account(family: @family, currency: "EUR")
    income_trade account: eur, date: @as_of - 5, amount: 2

    assert_equal true, income_locals[:rate_missing]
  end

  # 200 days back is inside the year and outside the 30-day period. The trailing
  # total is printed beside the period's, so its gap has to be flagged too.
  test "the income section flags a missing exchange rate that is only in the trailing year" do
    pay @as_of - 10, 5
    lay_history
    eur = create_portfolio_account(family: @family, currency: "EUR")
    income_trade account: eur, date: @as_of - 200, amount: 2

    assert_equal true, income_locals[:rate_missing]
  end

  # Visible and empty, not absent: see the comment on the registry entry.
  test "a period with no income still shows the section, with no bars" do
    lay_history

    section = registry.sections.find { |s| s[:key] == "income" }

    assert section[:visible]
    assert_empty section[:locals][:bars]
    assert_equal BigDecimal(0), section[:locals][:income][:total]
  end

  private
    def pay(date, amount)
      income_trade account: @account, date: date, amount: amount
      (@payouts ||= {})[date] = BigDecimal(amount.to_s)
    end

    # A balance row for every day from before the earliest payout to `as_of`,
    # stepping by exactly what was paid so each day's components add up.
    def lay_history
      running = BigDecimal(1_000)

      (Date.new(2025, 7, 1)..@as_of).each do |date|
        flow = (@payouts || {}).fetch(date, BigDecimal(0))
        lay_balance account: @account, date: date, opening: running, closing: running + flow, cash_flow: flow
        running += flow
      end
    end

    def registry
      Portfolio::SectionRegistry.new(
        statement: InvestmentStatement.new(@family, user: nil),
        period: @period,
        as_of: @as_of,
        user: nil
      )
    end

    def income_locals
      registry.sections.find { |section| section[:key] == "income" }[:locals]
    end
end
