require "test_helper"

class TradeTest < ActiveSupport::TestCase
  include PortfolioReturnsTestHelper

  test "build_name generates buy trade name" do
    name = Trade.build_name("buy", 10, "AAPL")
    assert_equal "Buy 10.0 shares of AAPL", name
  end

  test "build_name generates sell trade name" do
    name = Trade.build_name("sell", 5, "MSFT")
    assert_equal "Sell 5.0 shares of MSFT", name
  end

  test "build_name handles absolute value for negative quantities" do
    name = Trade.build_name("sell", -5, "GOOGL")
    assert_equal "Sell 5.0 shares of GOOGL", name
  end

  test "build_name handles decimal quantities" do
    name = Trade.build_name("buy", 0.25, "BTC")
    assert_equal "Buy 0.25 shares of BTC", name
  end

  test "price scale is preserved at 10 decimal places" do
    security = Security.create!(ticker: "TEST", exchange_operating_mic: "XNAS")

    # up to 10 decimal places — should persist exactly
    precise_price = BigDecimal("12.3456789012")
    trade = Trade.create!(
      security: security,
      price: precise_price,
      qty: 10000,
      currency: "USD",
      investment_activity_label: "Buy"
    )

    trade.reload

    assert_equal precise_price, trade.price
  end

  test "fee defaults to 0" do
    security = Security.create!(ticker: "FEETEST", exchange_operating_mic: "XNAS")
    trade = Trade.create!(
      security: security,
      price: 100,
      qty: 10,
      currency: "USD",
      investment_activity_label: "Buy"
    )

    assert_equal 0, trade.fee
  end

  test "exchange_rate setter stores normalized numeric value in extra" do
    trade = Trade.new
    trade.exchange_rate = "0.91"

    assert_equal 0.91, trade.exchange_rate
    assert_equal 0.91, trade.extra["exchange_rate"]
  end

  test "exchange_rate validation rejects invalid values" do
    trade = Trade.new
    trade.exchange_rate = "invalid"

    assert_not trade.valid?
    assert_includes trade.errors[:exchange_rate], "must be a number"
  end

  test "exchange_rate validation rejects non-finite values" do
    trade = Trade.new
    trade.exchange_rate = "NaN"

    assert_not trade.valid?
    assert_includes trade.errors[:exchange_rate], "must be a number"
  end

  test "price is rounded to 10 decimal places" do
    security = Security.create!(ticker: "TEST", exchange_operating_mic: "XNAS")

    # over 10 decimal places — will be rounded
    price_with_too_many_decimals = BigDecimal("1.123456789012345")
    trade = Trade.create!(
      security: security,
      price: price_with_too_many_decimals,
      qty: 1,
      currency: "USD",
      investment_activity_label: "Buy"
    )

    trade.reload

    assert_equal BigDecimal("1.1234567890"), trade.price
  end

  test "a transfer out realises nothing, however it is priced" do
    account, security = position_with_known_cost_basis

    moved = build_negative_trade(account, security, label: "Transfer")
    sold  = build_negative_trade(account, security, label: "Sell")

    # Same sign, same shape, same price — only the label separates a sale from
    # coins walking to another wallet you own.
    assert_nil moved.realized_gain_loss
    assert_not_nil sold.realized_gain_loss
  end

  test "every internal movement label realises nothing" do
    account, security = position_with_known_cost_basis

    Trade::INTERNAL_MOVEMENT_LABELS.each do |label|
      trade = build_negative_trade(account, security, label: label)
      assert_nil trade.realized_gain_loss, "#{label} should not realise a gain"
    end
  end

  # `Trend#value` is `current - previous` and `Money#-` neither converts nor
  # raises, so a disposal priced in the security's currency was having a basis
  # denominated in the account's subtracted from it as a bare number. The
  # proceeds are converted into the basis's currency first, at the disposal's
  # own date.
  #
  # A USD account holding a EUR-listed security: basis 100 USD/share, 2 sold at
  # 150 EUR/share, EUR->USD 1.5 on the trade date. 300 EUR of proceeds is 450
  # USD, less 200 USD of basis, so 250 USD. The unconverted subtraction reported
  # 100 -- and then labelled it USD.
  test "a disposal priced in another currency converts its proceeds at the trade date" do
    account = create_portfolio_account(family: families(:empty))
    date = Date.new(2026, 3, 10)

    holding_snapshot account: account, date: date, qty: 5, price: 150, cost_basis: 100
    sell = sell_trade(account: account, date: date, qty: 2, price: 150, currency: "EUR").entryable
    set_rate from: "EUR", to: "USD", date: date, rate: 1.5

    gain = sell.realized_gain_loss

    assert_equal BigDecimal(250), gain.value.amount
    assert_equal "USD", gain.value.currency.iso_code,
                 "the figure is carried in the currency the position is held in"
  end

  # The same defect at a rate below parity OVERSTATES, so a test at one rate
  # cannot pass by accident of direction. 300 EUR at 0.7 is 210 USD, less 200
  # USD of basis: a 10 USD gain, where the bare subtraction claimed 100.
  test "a disposal at a rate below parity is not overstated" do
    account = create_portfolio_account(family: families(:empty))
    date = Date.new(2026, 3, 10)

    holding_snapshot account: account, date: date, qty: 5, price: 150, cost_basis: 100
    sell = sell_trade(account: account, date: date, qty: 2, price: 150, currency: "EUR").entryable
    set_rate from: "EUR", to: "USD", date: date, rate: 0.7

    assert_equal BigDecimal(10), sell.realized_gain_loss.value.amount
  end

  # No rate for that date means the gain is unknown, not zero and not the
  # figure the rate would have been 1.0. The reason is recorded so a caller can
  # say WHICH fact it is missing rather than blaming the cost basis.
  test "a cross-currency disposal with no rate for its date has no figure" do
    account = create_portfolio_account(family: families(:empty))
    date = Date.new(2026, 3, 10)

    holding_snapshot account: account, date: date, qty: 5, price: 150, cost_basis: 100
    sell = sell_trade(account: account, date: date, qty: 2, price: 150, currency: "EUR").entryable
    set_rate from: "EUR", to: "USD", date: date - 1, rate: 1.5

    assert_nil sell.realized_gain_loss, "a neighbouring day's rate is not this day's"
    assert_equal :missing_exchange_rate, sell.realized_gain_loss_unavailable_reason
  end

  # `ExchangeRate` validates presence only -- no positivity at the model, and
  # `rate` is a plain `decimal, null: false` at the column -- so a provider or
  # an import can leave a 0 or a negative behind. Multiplying by one is not a
  # conversion: at 0 the 300 EUR of proceeds become nothing and the disposal
  # reports a 200 USD total loss the user never took, and at -1.5 the proceeds
  # go negative and the loss is 650. Neither is distinguishable on the page
  # from a real one, and both are tax-relevant.
  #
  # A rate that cannot convert is the missing-rate case, whatever is stored in
  # the row, so it takes the same exit.
  test "a disposal whose stored rate cannot convert has no figure" do
    [ 0, -1.5 ].each do |stored|
      account = create_portfolio_account(family: families(:empty))
      date = Date.new(2026, 3, 10)

      holding_snapshot account: account, date: date, qty: 5, price: 150, cost_basis: 100
      sell = sell_trade(account: account, date: date, qty: 2, price: 150, currency: "EUR").entryable
      set_rate from: "EUR", to: "USD", date: date, rate: stored

      assert_nil sell.realized_gain_loss, "a rate of #{stored} converts nothing"
      assert_equal :missing_exchange_rate, sell.realized_gain_loss_unavailable_reason,
                   "and it is the rate that is missing, not the basis"
    end
  end

  # The control: the guard rejects what cannot convert, not every rate below
  # parity. 300 EUR at 0.7 is a real conversion and must still produce a figure.
  test "a positive rate below parity still converts" do
    account = create_portfolio_account(family: families(:empty))
    date = Date.new(2026, 3, 10)

    holding_snapshot account: account, date: date, qty: 5, price: 150, cost_basis: 100
    sell = sell_trade(account: account, date: date, qty: 2, price: 150, currency: "EUR").entryable
    set_rate from: "EUR", to: "USD", date: date, rate: 0.7

    assert_equal BigDecimal(10), sell.realized_gain_loss.value.amount
  end

  test "a disposal with no cost basis says so rather than blaming a rate" do
    account = create_portfolio_account(family: families(:empty))
    date = Date.new(2026, 3, 10)

    sell = sell_trade(account: account, date: date, qty: 2, price: 150).entryable
    sell.preloaded_holdings = []

    assert_nil sell.realized_gain_loss
    assert_equal :missing_cost_basis, sell.realized_gain_loss_unavailable_reason
  end

  private
    # A position whose cost basis is known, which is what makes a fabricated
    # gain possible: without one, realized_gain_loss returns nil for any reason.
    def position_with_known_cost_basis
      family = families(:empty)
      account = family.accounts.create!(name: "Wallet", balance: 100, currency: "USD",
                                        accountable: Investment.new)
      security = Security.find_or_create_by!(ticker: "MOVE") { |s| s.name = "Movable" }
      Holding.create!(account: account, security: security, date: 10.days.ago.to_date,
                      qty: 100, price: 2, amount: 200, currency: "USD", cost_basis: 1)

      [ account, security ]
    end

    def build_negative_trade(account, security, label:)
      account.entries.create!(
        date: 3.days.ago.to_date, name: "out #{label}", amount: 0, currency: "USD",
        entryable: Trade.new(security: security, qty: -40, price: 3, currency: "USD",
                             investment_activity_label: label)
      ).entryable
    end

    # "Exchange" means a currency exchange on cash and is internal there. On a
    # security the label covers currency *or security* exchanges, and a
    # security-for-security exchange can dispose of an appreciated asset — so
    # borrowing Transaction's list erased a realized gain with nothing to show
    # for it.
    test "an exchange is not treated as an internal movement on a trade" do
      assert_not Trade.new(investment_activity_label: "Exchange").internal_movement?
    end

    test "the labels that unambiguously preserve ownership still are" do
      %w[Transfer Sweep\ In Sweep\ Out].each do |label|
        assert Trade.new(investment_activity_label: label).internal_movement?, label
      end
    end

    # The two lists are deliberately different; this fails if one is ever
    # realized_gain_loss memoises on first call, so a trade measured before its
    # holdings arrived would keep the figure it derived without them. The writer
    # clears that memo; attr_writer would not, and the stale figure would stand.
    test "assigning preloaded holdings re-derives a realised figure already taken" do
      family = families(:empty)
      account = create_portfolio_account(family: family)
      sell = sell_trade(account: account, date: Date.new(2026, 3, 10), qty: 2, price: 150).entryable

      sell.preloaded_holdings = []
      assert_nil sell.realized_gain_loss, "no holding means no basis, so no figure"

      sell.preloaded_holdings = [ account.holdings.create!(
        security: security_under_test, date: Date.new(2026, 3, 10), qty: 5, price: 150,
        amount: BigDecimal(750), currency: account.currency, cost_basis: 100
      ) ]

      assert_equal BigDecimal(100), sell.realized_gain_loss.value.amount,
                   "the second assignment must be read, not swallowed by the memo"
    end

    # aliased back onto the other.
    test "a trade does not borrow the cash list" do
      assert_includes Transaction::INTERNAL_MOVEMENT_LABELS, "Exchange"
      assert_not_includes Trade::INTERNAL_MOVEMENT_LABELS, "Exchange"
    end
end
