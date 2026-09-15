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

  # Regression. Asserting value_close alone was not enough: the account leaving
  # the scope drops it from value_close while value_open still carries
  # yesterday's close, so the ratio read -100% and #chain multiplied the whole
  # period's TWR by zero. Closing a broker made every historical return vanish.
  #
  # This went live when InvestmentStatement#performance moved to the historical
  # account scope (#119 D2) and started passing active_until_dates at all.
  test "the day an account leaves the scope is suppressed rather than read as a total loss" do
    lay_balance account: @account, date: @day_one, opening: 1_000, closing: 1_000

    returns = Portfolio::DailyReturns.new(
      account_ids: [ @account.id ],
      currency: @family.currency,
      period: Period.custom(start_date: @day_one, end_date: @day_two),
      active_until_dates: { @account.id => @day_one }
    )

    closing_day = returns.rows.last
    assert closing_day.suppressed, "a composition change is not a return"
    assert_equal BigDecimal("0"), returns.returns.to_h.fetch(@day_two),
                 "so it contributes nothing to the chain"

    # The balance did not evaporate, it left the scope. R12 puts that in
    # unexplained rather than attributing it to the market.
    assert_equal BigDecimal("-1000"), closing_day.unexplained
    assert_equal BigDecimal("0"), closing_day.market
  end

  # Regression: an empty foreign-currency account contributes nothing to any
  # figure, so it must not blank the portfolio. The flag was previously raised
  # for any in-scope account whose currency lacked a rate, whether or not it
  # held a balance, so adding an unsynced account suppressed every ratio for
  # every other account too.
  test "an unsynced foreign account holding no balance does not flag a missing rate" do
    lay_balance account: @account, date: @day_one, opening: 1_000, closing: 1_000
    lay_balance account: @account, date: @day_two, opening: 1_000, closing: 1_100, market_flow: 100
    empty_gbp = create_portfolio_account(family: @family, currency: "GBP")

    returns = daily_returns(account_ids: [ @account.id, empty_gbp.id ])

    refute returns.rate_missing?, "an account with no balances cannot be missing a conversion"
    assert_in_delta 0.10, returns.returns.last.last.to_f, 0.000001
  end

  # Regression: components used to be read from the carried-forward balance row,
  # so a day with no row of its own re-reported the previous day's market flow.
  # Over a gap that multiplied the market driver by the gap's length.
  test "a carried forward balance does not repeat its market flow on later days" do
    day_three = @day_two + 1.day
    lay_balance account: @account, date: @day_one, opening: 1_000, closing: 1_100, market_flow: 100
    # No rows for day two or day three: the balance is carried forward.

    rows = daily_returns(end_date: day_three).rows

    assert_equal BigDecimal("100"), rows.first.market
    assert_equal BigDecimal("0"), rows.second.market, "the gap must not re-earn day one's gain"
    assert_equal BigDecimal("0"), rows.third.market
  end

  # An entry whose `excluded` column is NULL rather than false: Ruby reads it as
  # a live flow, and a bare `excluded = false` in SQL evaluates to NULL and
  # drops the row. Left unaligned, the deposit vanishes from the denominator and
  # inflates the day's return.
  test "an entry with a null excluded flag is still counted as a flow" do
    lay_balance account: @account, date: @day_one, opening: 1_000, closing: 1_000
    lay_balance account: @account, date: @day_two, opening: 1_000, closing: 1_500, cash_flow: 500
    entry = deposit(account: @account, date: @day_two, amount: 500)
    entry.update_column(:excluded, nil)

    assert_nil entry.reload.excluded
    assert_equal BigDecimal("500"), daily_returns.rows.last.external_flow
    assert_in_delta 0.0, daily_returns.returns.last.last.to_f, 0.000001,
                    "the deposit explains the whole move, so the day returned nothing"
  end

  # R13 for flows. The account is in the family's currency and its balances
  # convert, but the deposit was recorded in euros and no EUR rate exists.
  # Converting it at parity would put 500 into the denominator as 500 dollars.
  test "a foreign currency flow with no rate is flagged rather than converted at parity" do
    lay_balance account: @account, date: @day_one, opening: 1_000, closing: 1_000
    lay_balance account: @account, date: @day_two, opening: 1_000, closing: 1_500, cash_flow: 500
    deposit account: @account, date: @day_two, amount: 500, currency: "EUR"

    returns = daily_returns

    assert returns.rate_missing?, "an unconvertible flow must be flagged"
    refute_equal BigDecimal("500"), returns.rows.last.external_flow,
                 "the flow must not be converted at parity"
  end

  # The balances stop at the cut-off date; the flows must stop with them, or a
  # deposit lands in the denominator of a day the account is no longer in.
  test "a flow after an account's cut off date is not counted" do
    lay_balance account: @account, date: @day_one, opening: 1_000, closing: 1_000
    deposit account: @account, date: @day_two, amount: 500

    returns = Portfolio::DailyReturns.new(
      account_ids: [ @account.id ],
      currency: @family.currency,
      period: Period.custom(start_date: @day_one, end_date: @day_two),
      active_until_dates: { @account.id => @day_one }
    )

    assert_equal BigDecimal("0"), returns.rows.last.external_flow
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

  # A security transferred in from a broker OUTSIDE the scope raises the closing
  # value without any money crossing the boundary that the flow sum can see: the
  # journal entry carries amount 0 (Questrade writes price: 0, amount: 0), and
  # external_flow is amount-weighted. The arriving position therefore lands in
  # the numerator with an unchanged denominator and reads as return.
  #
  # This pins the behaviour rather than endorsing it. It is NOT caught by
  # #unexplained either, because the balance row books the arrival as a market
  # flow, so the drivers identity still reconciles exactly. Whichever way this
  # is eventually settled -- valuing the journal, or excluding such a day --
  # this test is the thing that will fail and say so.
  test "a security journalled in from outside the scope reads as return, not flow" do
    lay_balance account: @account, date: @day_one, opening: 1_000, closing: 1_000
    lay_balance account: @account, date: @day_two, opening: 1_000, closing: 1_500, market_flow: 500
    security_journal account: @account, date: @day_two, qty: 5

    second = daily_returns.rows.last

    assert_equal BigDecimal("0"), second.external_flow,
                 "a zero-amount journal contributes no flow whatever class it is given"
    assert_equal BigDecimal("1000"), second.denominator,
                 "so the denominator is the opening value alone"

    returns = daily_returns.returns.map(&:last)
    assert_in_delta 0.50, returns.last.to_f, 0.000001,
                    "the whole arriving position is measured as a 50% day"

    assert_equal BigDecimal("0"), second.unexplained,
                 "and the drivers identity still reconciles, so nothing flags it"
  end

  # Regression. When the period starts after the last balance row, that row is
  # carried forward by the `lb` lateral. It was read for BOTH boundaries --
  # value_close from its end_balance, value_open from its start_balance -- so
  # the first day of the period re-reported a change that had already happened
  # before the period began, and left the difference in #unexplained.
  #
  # Here day one moved 1,000 -> 1,100 and the period starts the day after. The
  # portfolio does nothing in the period, so every day must return zero; reading
  # start_balance gave the first day day-one's +10% a second time.
  test "a balance row carried in from before the period opens at its closing level" do
    lay_balance account: @account, date: @day_one, opening: 1_000, closing: 1_100, market_flow: 100
    day_three = @day_two + 1.day

    rows = Portfolio::DailyReturns.new(
      account_ids: [ @account.id ],
      currency: @family.currency,
      period: Period.custom(start_date: @day_two, end_date: day_three)
    ).rows

    first = rows.first
    assert_equal BigDecimal("1100"), first.value_open,
                 "the carried row's closing level is the opening value, not its start_balance"
    assert_equal BigDecimal("1100"), first.value_close
    assert_equal BigDecimal("0"), first.unexplained,
                 "nothing happened in the period, so nothing is unexplained"
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
