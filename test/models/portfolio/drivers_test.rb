require "test_helper"

class Portfolio::DriversTest < ActiveSupport::TestCase
  include PortfolioReturnsTestHelper

  setup do
    @family = families(:empty) # USD
    @account = create_portfolio_account(family: @family)
    @day_one = Date.new(2026, 3, 2)
    @day_two = Date.new(2026, 3, 3)
  end

  # Contract R7. The fee is already inside the return, because it reduced the
  # closing balance on the day it was charged. Reporting it separately is what
  # lets a user see what it cost them without it being counted twice.
  test "fees reduce the return and are reported separately" do
    lay_balance account: @account, date: @day_one, opening: 1_000, closing: 1_000
    lay_balance account: @account, date: @day_two, opening: 1_000, closing: 990, cash_flow: -10
    fee_entry account: @account, date: @day_two, amount: 10

    drivers = drivers_for

    assert_equal BigDecimal("10"), drivers.fees
    assert_equal BigDecimal("0"), drivers.external_net, "a fee is not a withdrawal"
    assert_equal BigDecimal("-10"), drivers.change
    assert drivers.reconciles?
  end

  # Contract R10. This is the defect the drivers table would otherwise ship
  # with. Balance::BaseCalculator#market_value_change_on_date returns 0 unless
  # the account is :investment AND the day carries no valuation, and the forward
  # calculator skips it outright on a valuation day -- so a manually valued
  # account records its entire move in the adjustment columns. A drivers table
  # reading only net_market_flows reports a flat zero for those accounts.
  test "a valuation tracked account reports its move as revaluations not market" do
    lay_balance account: @account, date: @day_one, opening: 1_000, closing: 1_000
    lay_balance account: @account, date: @day_two, opening: 1_000, closing: 1_200, revaluation: 200

    drivers = drivers_for

    assert_equal BigDecimal("0"), drivers.market,
                 "net_market_flows is empty on a valuation day, and pretending otherwise would be a lie"
    assert_equal BigDecimal("200"), drivers.revaluations
    assert_equal BigDecimal("200"), drivers.market_including_revaluations,
                 "callers that just want 'the holdings moved' get one figure"
    assert drivers.reconciles?
  end

  # Contract R11. The local balance never moves; the rate does. Attributing that
  # to the market would say the holdings gained when they did not.
  test "fx effect carries a rate only move and market stays zero" do
    eur = create_portfolio_account(family: @family, currency: "EUR")
    lay_balance account: eur, date: @day_one, opening: 1_000, closing: 1_000

    set_rate from: "EUR", to: "USD", date: @day_one, rate: 1.0
    set_rate from: "EUR", to: "USD", date: @day_two, rate: 1.1

    drivers = drivers_for(account_ids: [ eur.id ])

    assert_equal BigDecimal("0"), drivers.market
    assert_equal BigDecimal("0"), drivers.revaluations
    assert_in_delta 100.0, drivers.fx_effect.to_f, 0.01
    assert drivers.reconciles?
  end

  # Contract R12. The whole table is worthless if the parts do not add up to the
  # whole, and each account shape composes its change differently.
  test "drivers reconcile to the period change for every account shape" do
    # 1. Trade-tracked, single currency: market flow plus income, a fee and a deposit.
    traded = create_portfolio_account(family: @family)
    lay_balance account: traded, date: @day_one, opening: 1_000, closing: 1_100, market_flow: 100
    lay_balance account: traded, date: @day_two, opening: 1_100, closing: 2_355,
                cash_flow: 1_040, market_flow: 215
    deposit account: traded, date: @day_two, amount: 1_000
    income_trade account: traded, date: @day_two, amount: 50
    fee_entry account: traded, date: @day_two, amount: 10

    traded_drivers = drivers_for(account_ids: [ traded.id ])
    assert traded_drivers.reconciles?, "trade-tracked: #{traded_drivers.to_h.inspect}"
    assert_equal BigDecimal("1000"), traded_drivers.external_net
    assert_equal BigDecimal("50"), traded_drivers.income
    assert_equal BigDecimal("10"), traded_drivers.fees
    assert_equal BigDecimal("315"), traded_drivers.market

    # 2. Valuation-tracked.
    valued = create_portfolio_account(family: @family)
    lay_balance account: valued, date: @day_one, opening: 500, closing: 500
    lay_balance account: valued, date: @day_two, opening: 500, closing: 650, revaluation: 150

    valued_drivers = drivers_for(account_ids: [ valued.id ])
    assert valued_drivers.reconciles?, "valuation-tracked: #{valued_drivers.to_h.inspect}"

    # 3. Foreign currency, with both a local move and a rate move.
    eur = create_portfolio_account(family: @family, currency: "EUR")
    lay_balance account: eur, date: @day_one, opening: 1_000, closing: 1_000
    lay_balance account: eur, date: @day_two, opening: 1_000, closing: 1_100, market_flow: 100
    set_rate from: "EUR", to: "USD", date: @day_one, rate: 1.0
    set_rate from: "EUR", to: "USD", date: @day_two, rate: 1.2

    eur_drivers = drivers_for(account_ids: [ eur.id ])
    assert eur_drivers.reconciles?, "foreign currency: #{eur_drivers.to_h.inspect}"
    assert eur_drivers.fx_effect.positive?, "a strengthening rate is a gain to this family"
  end

  test "an empty scope reports zeroes rather than raising" do
    drivers = drivers_for(account_ids: [])

    assert_equal BigDecimal("0"), drivers.change
    assert drivers.reconciles?
  end

  private
    def drivers_for(account_ids: [ @account.id ])
      Portfolio::Drivers.new(
        Portfolio::DailyReturns.new(
          account_ids: account_ids,
          currency: @family.currency,
          period: Period.custom(start_date: @day_one, end_date: @day_two)
        )
      )
    end
end
