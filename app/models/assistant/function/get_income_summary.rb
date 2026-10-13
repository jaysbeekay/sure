# frozen_string_literal: true

class Assistant::Function::GetIncomeSummary < Assistant::Function
  include Assistant::Function::PortfolioSupport

  class << self
    def name
      "get_income_summary"
    end

    def description
      <<~INSTRUCTIONS
        Returns the dividend and interest income the user's investment and crypto
        accounts paid over a period, as the portfolio page's income section shows it:
        income by calendar month, the total, the fees charged over the same period,
        the fee ratio (fees against the average value held), and income by security.

        by_security plus unattributed adds up to the total: unattributed is income
        with no security recorded, or naming a security this install does not have.

        rate_missing means a dividend, interest payment or fee was in a currency
        with no exchange rate, so it is left out: the figures may be understated
        and fee_ratio is null. Say so instead of quoting them as complete.
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

    income = performance.income.to_h.with_indifferent_access
    securities = Portfolio::IncomeBySecurity.new(amounts: income[:by_security], total: income[:total])

    {
      period: period_summary(period),
      currency: family.currency,
      available: true,
      rate_missing: performance.rate_missing?,
      months: Array(income[:buckets]).map { |bucket| { month: bucket[:month], income: money(bucket[:amount]) } },
      total: money(income[:total]),
      fees: money(income[:fees]),
      average_value: money(income[:average_value]),
      fee_ratio: percent(income[:fee_ratio]),
      by_security: securities.rows.map { |row| by_security_row(row) },
      unattributed: money(securities.unattributed)
    }
  end

  private
    # The page's table (Portfolio::IncomeBySecurity): a row per security this
    # install knows, largest first, and everything else in `unattributed`, so
    # the rows and the remainder add up to the total by construction.
    def by_security_row(row)
      { security_id: row.security.id, ticker: row.security.ticker, name: row.security.name, income: money(row.amount) }
    end
end
