require "test_helper"

class Portfolio::DailyReturnsTest < ActiveSupport::TestCase
  include PortfolioReturnsTestHelper

  setup do
    @family = families(:empty) # currency USD
    @account = create_portfolio_account(family: @family)
    @day_one = Date.new(2026, 3, 2)
    @day_two = Date.new(2026, 3, 3)
  end

  # Contract R1. The hand-computed arithmetic:
  #
  #   day 1: 1000 -> 1100, no flow          r = 1100 / 1000       - 1 = 0.10
  #   day 2: 1100 -> 2310, 1000 deposited   r = 2310 / (1100+1000) - 1 = 0.10
  #
  # The deposit belongs in the DENOMINATOR. Put it in the numerator instead
  # (end-of-day convention) and day two reads 2310/1100 - 1 = 1.10 -- a 110%
  # day, produced entirely by the user moving their own money.
  test "start of day flow convention places the flow in the denominator" do
    lay_balance account: @account, date: @day_one, opening: 1_000, closing: 1_100, market_flow: 100
    lay_balance account: @account, date: @day_two, opening: 1_100, closing: 2_310,
                cash_flow: 1_000, market_flow: 210
    deposit account: @account, date: @day_two, amount: 1_000

    rows = daily_returns.rows
    second = rows.last

    assert_equal 2, rows.size
    assert_equal BigDecimal("1100"), second.value_open
    assert_equal BigDecimal("1000"), second.external_flow
    assert_equal BigDecimal("2100"), second.denominator, "the flow must be inside the denominator"

    returns = daily_returns.returns.map(&:last)
    assert_in_delta 0.10, returns.first.to_f, 0.000001
    assert_in_delta 0.10, returns.last.to_f, 0.000001
  end

  # Contract R2. The account does not move in its own currency; the rate does.
  # Because returns are quoted in the family's currency, that is a real 10% day
  # for this family, and it must appear as one.
  test "exchange rate movement alone produces a return" do
    eur = create_portfolio_account(family: @family, currency: "EUR")
    lay_balance account: eur, date: @day_one, opening: 1_000, closing: 1_000

    set_rate from: "EUR", to: "USD", date: @day_one, rate: 1.0
    set_rate from: "EUR", to: "USD", date: @day_two, rate: 1.1

    returns = daily_returns(account_ids: [ eur.id ]).returns.map(&:last)

    assert_in_delta 0.10, returns.last.to_f, 0.000001,
                    "a rate move with a flat local balance is still a return to this family"
  end

  # Contract R6. A full withdrawal leaves V_open + F == 0. Dividing by it raises;
  # allowing a negative denominator through is worse, because it silently
  # reverses the sign of the day's return.
  test "a non positive denominator suppresses the day rather than inverting it" do
    lay_balance account: @account, date: @day_one, opening: 1_000, closing: 1_000
    lay_balance account: @account, date: @day_two, opening: 1_000, closing: 0, cash_flow: -1_000
    deposit account: @account, date: @day_two, amount: -1_000

    rows = daily_returns.rows
    second = rows.last

    assert_equal BigDecimal("-1000"), second.external_flow
    assert_equal BigDecimal("0"), second.denominator
    assert second.suppressed, "a zero denominator must be suppressed"
    assert_equal [ @day_two ], daily_returns.suppressed_rows.map(&:date)
    assert_equal BigDecimal("0"), daily_returns.returns.last.last
  end

  # Contract R13. `InvestmentStatement#period_return_trend` converts a missing
  # rate at parity (COALESCE(rate, 1)), which turns 1,000 EUR into 1,000 USD
  # without saying so. A missing pair has to be visible.
  test "a currency pair with no rate is flagged rather than converted at parity" do
    eur = create_portfolio_account(family: @family, currency: "EUR")
    lay_balance account: eur, date: @day_one, opening: 1_000, closing: 1_000
    # No ExchangeRate rows exist for EUR -> USD at all.

    returns = daily_returns(account_ids: [ eur.id ])

    assert returns.rate_missing?, "a pair with no rate anywhere must be flagged"
    refute_equal BigDecimal("1000"), returns.rows.first.value_close,
                 "a missing rate must not silently produce the parity-converted figure"
  end

  test "a buy is internal and does not enter the external flow" do
    lay_balance account: @account, date: @day_one, opening: 1_000, closing: 1_000
    lay_balance account: @account, date: @day_two, opening: 1_000, closing: 1_000
    buy_trade account: @account, date: @day_two, qty: 2, price: 100

    assert_equal BigDecimal("0"), daily_returns.rows.last.external_flow,
                 "a buy moves cash into holdings inside the account; it is not a contribution"
  end

  test "a dividend is income rather than an external flow" do
    lay_balance account: @account, date: @day_one, opening: 1_000, closing: 1_000
    lay_balance account: @account, date: @day_two, opening: 1_000, closing: 1_050, cash_flow: 50
    income_trade account: @account, date: @day_two, amount: 50

    row = daily_returns.rows.last

    assert_equal BigDecimal("50"), row.income
    assert_equal BigDecimal("0"), row.external_flow,
                 "classifying income as a flow would cancel it out of the return entirely"
  end

  test "a transaction shaped dividend is income too" do
    lay_balance account: @account, date: @day_one, opening: 1_000, closing: 1_000
    lay_balance account: @account, date: @day_two, opening: 1_000, closing: 1_050, cash_flow: 50
    income_transaction account: @account, date: @day_two, amount: 50

    row = daily_returns.rows.last

    assert_equal BigDecimal("50"), row.income, "the provider shape must not change the classification"
    assert_equal BigDecimal("0"), row.external_flow
  end

  test "an excluded entry contributes no flow" do
    lay_balance account: @account, date: @day_one, opening: 1_000, closing: 1_000
    lay_balance account: @account, date: @day_two, opening: 1_000, closing: 1_000
    entry = deposit(account: @account, date: @day_two, amount: 500)
    entry.update!(excluded: true)

    assert_equal BigDecimal("0"), daily_returns.rows.last.external_flow
  end

  test "a disabled account stops contributing after its cut off date" do
    lay_balance account: @account, date: @day_one, opening: 1_000, closing: 1_000

    returns = Portfolio::DailyReturns.new(
      account_ids: [ @account.id ],
      currency: @family.currency,
      period: Period.custom(start_date: @day_one, end_date: @day_two),
      active_until_dates: { @account.id => @day_one }
    )

    assert_equal BigDecimal("1000"), returns.rows.first.value_close
    assert_equal BigDecimal("0"), returns.rows.last.value_close,
                 "the account is closed on day two and must contribute nothing"
  end

  test "returns are empty without accounts" do
    returns = Portfolio::DailyReturns.new(
      account_ids: [],
      currency: @family.currency,
      period: Period.custom(start_date: @day_one, end_date: @day_two)
    )

    assert_empty returns.rows
    assert_empty returns.returns
    refute returns.any?
  end

  private
    def daily_returns(account_ids: [ @account.id ], start_date: @day_one, end_date: @day_two)
      Portfolio::DailyReturns.new(
        account_ids: account_ids,
        currency: @family.currency,
        period: Period.custom(start_date: start_date, end_date: end_date)
      )
    end
end
