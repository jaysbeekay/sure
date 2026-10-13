# frozen_string_literal: true

# Shared plumbing for the portfolio tools. Every figure comes from
# InvestmentStatement for the calling user, which scopes accounts with
# Account.included_in_finances_for(user) -- the same accounts, and so the same
# numbers, the portfolio pages show that user.
#
# Periods are the period picker's presets, except "all_time": its range is
# anchored on Current.family, which a tool call (a job, or an MCP request) does
# not set. An explicit start_date/end_date covers any other range. The two month
# presets follow the family's custom month start, as the picker's do.
module Assistant::Function::PortfolioSupport
  PERIOD_KEYS = %w[current_month last_month last_30_days last_90_days current_year last_365_days last_5_years].freeze
  DEFAULT_PERIOD_KEY = "current_year"

  private
    def period_properties
      {
        period: {
          type: "string",
          enum: PERIOD_KEYS,
          description: "Preset period (default #{DEFAULT_PERIOD_KEY}). Ignored when start_date and end_date are given."
        },
        start_date: { type: "string", description: "Custom period start (YYYY-MM-DD); needs end_date" },
        end_date: { type: "string", description: "Custom period end (YYYY-MM-DD); needs start_date" }
      }
    end

    # A Period, or an error hash the caller returns as is. A malformed or
    # half-given range fails loudly: silently falling back to the default
    # would present one period's figures as another's.
    def resolve_period(params)
      start_raw, end_raw = params["start_date"].presence, params["end_date"].presence

      if start_raw || end_raw
        return portfolio_error("invalid_date", "Give both start_date and end_date, in YYYY-MM-DD format.") unless start_raw && end_raw

        start_date = Date.iso8601(start_raw.to_s)
        end_date = Date.iso8601(end_raw.to_s)
        return portfolio_error("invalid_date", "start_date must be on or before end_date.") if start_date > end_date

        return Period.custom(start_date: start_date, end_date: end_date)
      end

      key = params["period"].presence || DEFAULT_PERIOD_KEY
      return portfolio_error("invalid_period", "period must be one of: #{PERIOD_KEYS.join(", ")}.") unless key.in?(PERIOD_KEYS)

      case key
      when "current_month" then Period.current_month_for(family)
      when "last_month" then Period.last_month_for(family)
      else Period.from_key(key)
      end
    rescue Date::Error
      portfolio_error("invalid_date", "Dates must be valid and in YYYY-MM-DD format.")
    end

    def investment_statement
      @investment_statement ||= InvestmentStatement.new(family, user: user)
    end

    # What return method each account's records support over the period, keyed
    # by account id, for the same accounts #performance measures.
    def return_scopes(period)
      @return_scopes ||= {}
      @return_scopes[[ period.start_date, period.end_date ]] ||= investment_statement.return_scopes(period: period)
    end

    # Whether any account in scope has a balance row in the period. The daily
    # rows exist for every calendar day of the period whatever the accounts
    # hold, so Portfolio::Performance#any? is true for an account with no
    # history at all, and its return chains to 0%. That is not a measured
    # portfolio, so the tools report it as unavailable.
    def history_in?(period)
      return_scopes(period).values.any? { |scope| scope.balance_days.positive? }
    end

    def unavailable(period)
      {
        period: period_summary(period),
        available: false,
        message: "No investment or crypto account history in this period for this user."
      }
    end

    def period_summary(period)
      { key: period.key, start_date: period.start_date, end_date: period.end_date }.compact
    end

    # A fraction (0.21) as a rounded number and a percentage string, or nil
    # when the model withheld the figure.
    def percent(fraction)
      return nil if fraction.nil?

      { value: fraction.to_d.round(6).to_f, formatted: "#{(fraction.to_d * 100).round(2).to_s("F")}%" }
    end

    def money(amount)
      return nil if amount.nil?

      money = amount.is_a?(Money) ? amount : Money.new(amount, family.currency)
      { amount: money.amount.round(money.currency.default_precision).to_f, formatted: money.format }
    end

    def portfolio_error(key, message)
      { error: key, message: message }
    end
end
