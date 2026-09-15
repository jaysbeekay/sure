require "test_helper"

class Portfolio::ReturnScopeTest < ActiveSupport::TestCase
  include PortfolioReturnsTestHelper

  setup do
    @family = families(:empty)
    @account = create_portfolio_account(family: @family)
    @day_one = Date.new(2026, 3, 2)
    @day_two = Date.new(2026, 3, 3)
    @period = Period.custom(start_date: @day_one, end_date: @day_two)
  end

  # Contract R15. One point is a position, not a return. Quoting a figure from
  # it would mean inventing an opening value.
  test "an account with one balance day is insufficient" do
    lay_balance account: @account, date: @day_one, opening: 1_000, closing: 1_000

    scope = Portfolio::ReturnScope.new(account: @account, period: @period)

    assert scope.insufficient?
    refute scope.supports_time_weighted_return?
    refute scope.supports_money_weighted_return?
  end

  # Contract R16. Without trades or transfers there is no record of what was
  # paid in, so an XIRR over "the flows" would be an XIRR over an empty set
  # dressed up as a measurement.
  test "a valuation tracked account does not support money weighted return" do
    lay_balance account: @account, date: @day_one, opening: 1_000, closing: 1_000
    lay_balance account: @account, date: @day_two, opening: 1_000, closing: 1_200, revaluation: 200
    create_valuation_entry(date: @day_two, amount: 1_200)

    scope = Portfolio::ReturnScope.new(account: @account, period: @period)

    assert scope.valuation_tracked?
    assert scope.supports_time_weighted_return?, "the value still changed, and that change is reportable"
    refute scope.supports_money_weighted_return?
    assert_equal "value_return", scope.return_label_key
  end

  test "an account with trades is trade tracked and supports both methods" do
    lay_balance account: @account, date: @day_one, opening: 1_000, closing: 1_000
    lay_balance account: @account, date: @day_two, opening: 1_000, closing: 1_000
    buy_trade account: @account, date: @day_two, qty: 2, price: 100

    scope = Portfolio::ReturnScope.new(account: @account, period: @period)

    assert scope.trade_tracked?
    assert scope.supports_time_weighted_return?
    assert scope.supports_money_weighted_return?
    assert_equal "time_weighted_return", scope.return_label_key
  end

  test "an account whose only records are external transfers is trade tracked" do
    lay_balance account: @account, date: @day_one, opening: 1_000, closing: 1_000
    lay_balance account: @account, date: @day_two, opening: 1_000, closing: 1_500, cash_flow: 500
    deposit account: @account, date: @day_two, amount: 500

    scope = Portfolio::ReturnScope.new(account: @account, period: @period)

    assert scope.trade_tracked?, "a known deposit is enough to know the flows"
    assert scope.supports_money_weighted_return?
  end

  test "balances with no explanation at all are treated as valuation tracked" do
    lay_balance account: @account, date: @day_one, opening: 1_000, closing: 1_000
    lay_balance account: @account, date: @day_two, opening: 1_000, closing: 1_100, market_flow: 100

    scope = Portfolio::ReturnScope.new(account: @account, period: @period)

    assert scope.valuation_tracked?,
           "the value change is real and reportable; the flows behind it are not known"
    refute scope.supports_money_weighted_return?
  end

  # F9: an excluded trade is not a record of anything, so it cannot make the
  # account's flows known.
  test "an excluded trade does not make an account trade tracked" do
    lay_balance account: @account, date: @day_one, opening: 1_000, closing: 1_000
    lay_balance account: @account, date: @day_two, opening: 1_000, closing: 1_100, market_flow: 100
    buy_trade(account: @account, date: @day_two, qty: 1, price: 10).update!(excluded: true)

    scope = Portfolio::ReturnScope.new(account: @account, period: @period)

    assert scope.valuation_tracked?
    refute scope.supports_money_weighted_return?
  end

  # Trades and valuations are read up to the end of the period, so transfers
  # must be too: a deposit made before the period is still a known flow.
  test "a transfer before the period still marks the account trade tracked" do
    lay_balance account: @account, date: @day_one, opening: 1_000, closing: 1_000
    lay_balance account: @account, date: @day_two, opening: 1_000, closing: 1_100, market_flow: 100
    deposit account: @account, date: @day_one - 10.days, amount: 1_000

    scope = Portfolio::ReturnScope.new(account: @account, period: @period)

    assert scope.trade_tracked?
  end

  # `entries.excluded` is nullable and F9 reads NULL as live. A bare
  # `excluded = false` drops such a row.
  test "a deposit with a null excluded flag is a known flow" do
    lay_balance account: @account, date: @day_one, opening: 1_000, closing: 1_000
    lay_balance account: @account, date: @day_two, opening: 1_000, closing: 1_500, cash_flow: 500
    deposit(account: @account, date: @day_two, amount: 500).update_column(:excluded, nil)

    scope = Portfolio::ReturnScope.new(account: @account, period: @period)

    assert scope.trade_tracked?
  end

  private
    def create_valuation_entry(date:, amount:)
      @account.entries.create!(
        name: "Valuation",
        date: date,
        amount: amount,
        currency: @account.currency,
        entryable: Valuation.new(kind: "reconciliation")
      )
    end
end
