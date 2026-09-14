# Where a period's change in portfolio value came from.
#
# Implements contract rows R7, R10, R11 and R12.
#
# The components reconcile exactly to the period's change in value (R12):
#
#   external_net + income - fees + market + revaluations + fx_effect
#     == value_close - value_open
#
# TWO THINGS ARE EASY TO GET WRONG HERE, and both are contract rows.
#
# R10: `balances.net_market_flows` is only populated for investment accounts on
# days WITHOUT a valuation (Balance::BaseCalculator#market_value_change_on_date
# returns 0 otherwise, and the forward calculator skips it entirely on a
# valuation day). When a valuation overrides the balance, the whole move lands
# in cash_adjustments / non_cash_adjustments instead. Reporting only
# `net_market_flows` as "market" would therefore show a flat zero market return
# for every manually valued account. Those adjustments are reported here as
# `revaluations`, and Portfolio::ReturnScope tells the UI which label an account
# has earned.
#
# R11: `fx_effect` is MEASURED, not inferred. Portfolio::DailyReturns computes
# it per day as the closing local balance times that day's rate change, and the
# local components are converted at the previous day's rate, so the two halves
# add up to the day's change by construction rather than by definition.
#
# An earlier version defined fx_effect as the residual of R12's own equation.
# That made `reconciles?` a tautology -- it could not return false, so the
# contract's most important row was guarded by an assertion that could not
# fail, and a portfolio whose value moved for no recorded reason reported the
# whole move as currency movement. `unexplained` now carries that gap openly.
class Portfolio::Drivers
  attr_reader :daily_returns

  def initialize(daily_returns)
    @daily_returns = daily_returns
  end

  def rows
    daily_returns.rows
  end

  def value_open
    @value_open ||= rows.first&.value_open || BigDecimal(0)
  end

  def value_close
    @value_close ||= rows.last&.value_close || BigDecimal(0)
  end

  def change
    value_close - value_open
  end

  # Net external contribution: deposits and transfers in, less withdrawals.
  def external_net
    @external_net ||= sum(:external_flow)
  end

  # Dividends and interest thrown off by the holdings (contract F1/F4).
  def income
    @income ||= sum(:income)
  end

  # Reported as a positive magnitude; it reduces the change (R7).
  def fees
    @fees ||= sum(:fees)
  end

  # Market movement on trade-tracked accounts.
  def market
    @market ||= sum(:market)
  end

  # Valuation and reconciliation movement (R10). For a valuation-tracked
  # account this carries the entire market move.
  def revaluations
    @revaluations ||= sum(:revaluations)
  end

  # R11: measured per day from the rate change, not inferred.
  def fx_effect
    @fx_effect ||= sum(:fx_effect)
  end

  # What the named components do not account for. Expected to be zero, and a
  # real assertion because nothing defines it to be.
  #
  # It is non-zero when the portfolio's COMPOSITION changed rather than its
  # value: an account whose first balance row falls inside the period brings an
  # opening position that no driver describes, and an account leaving takes one
  # away. Surfacing that is the honest answer -- the alternative is to fold it
  # into whichever component is defined last and call the books balanced.
  def unexplained
    @unexplained ||= change - (external_net + income - fees + market + revaluations + fx_effect)
  end

  # For an account whose scope is :valuation_tracked, the market move lives in
  # `revaluations`. Callers that want one "the holdings moved" figure without
  # caring which shape the account is should use this.
  def market_including_revaluations
    market + revaluations
  end

  def to_h
    {
      value_open: value_open,
      value_close: value_close,
      change: change,
      external_net: external_net,
      income: income,
      fees: fees,
      market: market,
      revaluations: revaluations,
      fx_effect: fx_effect,
      unexplained: unexplained
    }
  end

  # R12. A real check: `unexplained` is measured independently of the components
  # it is compared against, so this returns false when the decomposition does
  # not hold.
  def reconciles?(tolerance: BigDecimal("0.01"))
    unexplained.abs <= tolerance
  end

  private
    def sum(field)
      rows.sum(BigDecimal(0)) { |row| row.public_send(field) }
    end
end
