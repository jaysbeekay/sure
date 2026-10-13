# frozen_string_literal: true

class Assistant::Function::GetPortfolioPerformance < Assistant::Function
  include Assistant::Function::PortfolioSupport

  class << self
    def name
      "get_portfolio_performance"
    end

    def description
      <<~INSTRUCTIONS
        Returns how the user's investment and crypto accounts performed over a period,
        as the portfolio page shows it: time-weighted return (the investments' own
        performance, with deposits and withdrawals removed), money-weighted return,
        volatility, maximum drawdown, and what drove the change in value
        (contributions, income, fees, market movement, revaluations and currency
        effects).

        The money-weighted return, in the portfolio page's words: #{I18n.t("portfolios.performance.mwr_hint", locale: :en)}

        A figure is null when it is withheld, never when it is zero:
        - annualised returns need at least a year of history;
        - rate_missing means a currency had no exchange rate in the period, so no
          return is reported rather than one converted at a guessed rate;
        - return_scopes lists each account with history in the period, the return
          methods its records support, and withheld_because when one is not. One
          account that cannot support a method withholds that figure for the whole
          portfolio.
        Say why a figure is missing instead of treating it as 0.
      INSTRUCTIONS
    end
  end

  def strict_mode?
    false
  end

  def params_schema
    build_schema(required: [], properties: period_properties)
  end

  def call(params = {})
    period = resolve_period(params)
    return period if period.is_a?(Hash)

    performance = investment_statement.performance(period: period)

    return unavailable(period) unless performance.any? && history_in?(period)

    {
      period: period_summary(period),
      currency: family.currency,
      available: true,
      rate_missing: performance.rate_missing?,
      time_weighted_return: percent(performance.time_weighted_return),
      annualized_time_weighted_return: percent(performance.annualized_time_weighted_return),
      money_weighted_return: percent(performance.money_weighted_return),
      annualized_money_weighted_return: percent(performance.annualized_money_weighted_return),
      volatility: percent(performance.volatility),
      max_drawdown: percent(performance.max_drawdown),
      suppressed_days: Array(performance.suppressed_dates).size,
      return_scopes: return_scope_rows(period),
      drivers: drivers(performance.drivers)
    }
  end

  private
    # What each account's records support (contract rows R15 and R16), so a
    # withheld return comes with its reason. Only accounts with balance rows in
    # the period: one with none neither contributes nor withholds, which is how
    # Portfolio::Performance treats it.
    def return_scope_rows(period)
      return_scopes(period).values
        .select { |scope| scope.balance_days.positive? }
        .sort_by { |scope| scope.account.name.to_s }
        .map do |scope|
          {
            account_id: scope.account.id,
            account: scope.account.name,
            tracking: scope.kind.to_s,
            time_weighted_return: scope.supports_time_weighted_return?,
            money_weighted_return: scope.supports_money_weighted_return?,
            withheld_because: withheld_because(scope)
          }
        end
    end

    def withheld_because(scope)
      if scope.insufficient?
        "Fewer than two days of balance history in the period, so the account has no return; " \
          "it withholds the portfolio's time-weighted and money-weighted figures."
      elsif scope.valuation_tracked?
        "Valued by valuations, with no record of money paid in or out, so its time-weighted figure " \
          "is a value return and it has no money-weighted return; it withholds the portfolio's money-weighted figure."
      end
    end

    def drivers(values)
      return nil if values.blank?

      values.to_h.transform_values { |amount| money(amount) }
    end
end
