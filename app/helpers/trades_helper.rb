module TradesHelper
  # A lot as the sale's picker lists it. Without a figure for what was left on
  # the sale's date, it says what was bought rather than guess.
  def lot_option_label(lot, shares)
    values = { date: l(lot.date, format: :long), bought: format_quantity(shares.bought, exact: true), price: lot.trade.price_money.format }
    return t("trades.show.lot_option_left_unknown", **values) if shares.left.nil?

    t("trades.show.lot_option", **values, left: format_quantity(shares.left, exact: true))
  end
end
