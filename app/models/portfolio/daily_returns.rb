# The daily return series a set of accounts produced over a period, in the
# family's currency.
#
# Implements rows R1, R2, R6 and R13 of docs/portfolio/returns-contract.md.
#
# Division of labour (contract §Scope): the database does the joining, windowing
# and FX -- what it is good at -- and returns raw components. The arithmetic that
# has to be exact and auditable happens here in BigDecimal, where it can be unit
# tested without a fixture round-trip. Computing `r_t` inside a CASE expression
# would bury the flow convention in SQL and make R1 a query edit.
#
# The query is always DAILY regardless of what interval a chart eventually
# displays (R3): chaining at a coarser interval silently changes the answer
# whenever a flow lands mid-interval.
class Portfolio::DailyReturns
  # One day. `r` is nil until #returns computes it, so a caller reading rows
  # directly cannot mistake a raw component for a return.
  Row = Data.define(
    :date, :value_open, :value_close, :external_flow,
    :income, :fees, :market, :revaluations, :rate_missing, :suppressed
  ) do
    def denominator
      value_open + external_flow
    end

    # R6: zero or negative denominators are suppressed rather than inverted.
    def computable?
      denominator.positive?
    end
  end

  attr_reader :account_ids, :currency, :period, :active_until_dates, :scope_account_ids

  # `scope_account_ids` is what the flow classifier treats as "inside" -- see
  # Portfolio::FlowClassifier. It defaults to `account_ids` (the natural reading:
  # a scope is external to everything it does not contain), but a caller
  # computing one account's return inside a wider portfolio can pass the wider
  # set to keep internal transfers internal.
  def initialize(account_ids:, currency:, period:, active_until_dates: {}, scope_account_ids: nil)
    @account_ids = Array(account_ids).compact.map(&:to_s)
    @currency = currency
    @period = period
    @active_until_dates = (active_until_dates || {}).compact
      .transform_keys(&:to_s)
      .transform_values { |date| date.to_date.iso8601 }
    @scope_account_ids = Array(scope_account_ids || @account_ids).compact.map(&:to_s)
  end

  # Every day in the period, with its raw components. Empty when no accounts.
  def rows
    @rows ||= begin
      return [] if account_ids.empty?

      previous_close = nil

      raw_rows.map do |raw|
        value_close = decimal(raw["value_close"])

        # R1: the opening value is the previous day's close. On the first day of
        # the period there is no previous row, so the balance row's own
        # start_balance is used -- which is the prior day's close by
        # construction (balances.start_balance == the previous end_balance).
        value_open = previous_close || decimal(raw["value_open"])
        previous_close = value_close

        external_flow = decimal(raw["external_flow"])
        denominator = value_open + external_flow

        Row.new(
          date: raw["date"].to_date,
          value_open: value_open,
          value_close: value_close,
          external_flow: external_flow,
          income: decimal(raw["income"]),
          fees: decimal(raw["fees"]),
          market: decimal(raw["market"]),
          revaluations: decimal(raw["revaluations"]),
          rate_missing: raw["rate_missing"] == true,
          suppressed: !denominator.positive?
        )
      end
    end
  end

  # [[date, r_t], ...] in BigDecimal. Suppressed days contribute a return of
  # zero (R6) and stay in the series so the calendar is unbroken.
  def returns
    @returns ||= rows.map do |row|
      r = if row.computable?
        (row.value_close / row.denominator) - 1
      else
        BigDecimal(0)
      end

      [ row.date, r ]
    end
  end

  # Days the contract required us to drop (R6). Surfaced rather than hidden so
  # the UI can say why a figure is not what a user expects.
  def suppressed_rows
    rows.select(&:suppressed)
  end

  # R13. True when any account's currency had no rate to the family currency on
  # any day of the period. The caller suppresses the figure; it must never fall
  # back to a parity conversion.
  def rate_missing?
    rows.any?(&:rate_missing)
  end

  def any?
    rows.any?
  end

  private
    def decimal(value)
      return BigDecimal(0) if value.nil?
      BigDecimal(value.to_s)
    end

    def raw_rows
      ActiveRecord::Base.connection.select_all(
        ActiveRecord::Base.sanitize_sql_array([ query, query_binds ])
      ).to_a
    end

    def query_binds
      {
        account_ids: account_ids,
        scope_account_ids: scope_account_ids,
        target_currency: currency,
        start_date: period.start_date,
        end_date: period.end_date,
        active_until_json: active_until_dates.to_json
      }
    end

    # Mirrors Balance::ChartSeriesBuilder's structure deliberately: the same
    # LATERAL LOCF over balances, the same two-way LOCF over exchange_rates, and
    # the same active-until windowing. The FX half is why -- the older pattern in
    # InvestmentStatement#period_return_trend joins `er.date = b.date` and
    # COALESCEs a miss to 1, silently converting at parity on every weekend and
    # holiday (contract R13).
    def query
      <<~SQL
        WITH dates AS (
          SELECT generate_series(DATE :start_date, DATE :end_date, '1 day'::interval)::date AS date
        ),
        account_windows AS (
          SELECT
            account_window.account_id::uuid AS account_id,
            account_window.active_until_date::date AS active_until_date
          FROM jsonb_each_text(CAST(:active_until_json AS jsonb))
            AS account_window(account_id, active_until_date)
        ),
        scoped_accounts AS (
          SELECT accounts.id, accounts.currency, account_windows.active_until_date
          FROM accounts
          LEFT JOIN account_windows ON account_windows.account_id = accounts.id
          WHERE accounts.id = ANY(array[:account_ids]::uuid[])
        ),
        balances_by_date AS (
          SELECT
            d.date,
            -- flows_factor is +1 for assets and -1 for liabilities. Investment
            -- and Crypto are always assets, so this is an identity here; it is
            -- applied anyway so the expression matches the chart series builder
            -- and cannot silently invert if the scope ever widens.
            COALESCE(SUM(lb.end_balance   * lb.flows_factor * er.rate), 0) AS value_close,
            COALESCE(SUM(lb.start_balance * lb.flows_factor * er.rate), 0) AS value_open,
            COALESCE(SUM(lb.net_market_flows * lb.flows_factor * er.rate), 0) AS market,
            COALESCE(SUM((lb.cash_adjustments + lb.non_cash_adjustments)
                         * lb.flows_factor * er.rate), 0) AS revaluations,
            BOOL_OR(sa.id IS NOT NULL AND sa.currency <> :target_currency AND er.rate IS NULL) AS rate_missing
          FROM dates d
          LEFT JOIN scoped_accounts sa
            ON sa.active_until_date IS NULL OR d.date <= sa.active_until_date
          LEFT JOIN LATERAL (
            SELECT b.end_balance, b.start_balance, b.net_market_flows,
                   b.cash_adjustments, b.non_cash_adjustments, b.flows_factor
            FROM balances b
            WHERE b.account_id = sa.id
              AND b.currency = sa.currency
              AND b.date <= d.date
            ORDER BY b.date DESC
            LIMIT 1
          ) lb ON TRUE
          LEFT JOIN LATERAL (
            SELECT CASE
              WHEN sa.currency = :target_currency THEN 1::numeric
              ELSE COALESCE(
                (SELECT r.rate FROM exchange_rates r
                  WHERE r.from_currency = sa.currency
                    AND r.to_currency = :target_currency
                    AND r.date <= d.date
                  ORDER BY r.date DESC LIMIT 1),
                (SELECT r.rate FROM exchange_rates r
                  WHERE r.from_currency = sa.currency
                    AND r.to_currency = :target_currency
                    AND r.date > d.date
                  ORDER BY r.date ASC LIMIT 1)
              )
            END AS rate
          ) er ON TRUE
          GROUP BY d.date
        ),
        flows_by_date AS (
          SELECT
            entries.date AS date,
            COALESCE(SUM(CASE WHEN #{flow_class_sql} = 'external'
                              THEN -entries.amount * fx.rate ELSE 0 END), 0) AS external_flow,
            COALESCE(SUM(CASE WHEN #{flow_class_sql} = 'income'
                              THEN -entries.amount * fx.rate ELSE 0 END), 0) AS income,
            COALESCE(SUM(CASE WHEN #{flow_class_sql} = 'fee'
                              THEN  entries.amount * fx.rate ELSE 0 END), 0) AS fees
          FROM entries
          JOIN accounts entry_accounts ON entry_accounts.id = entries.account_id
          #{flow_class_joins}
          LEFT JOIN LATERAL (
            SELECT CASE
              WHEN COALESCE(entries.currency, entry_accounts.currency) = :target_currency THEN 1::numeric
              ELSE COALESCE(
                (SELECT r.rate FROM exchange_rates r
                  WHERE r.from_currency = COALESCE(entries.currency, entry_accounts.currency)
                    AND r.to_currency = :target_currency
                    AND r.date <= entries.date
                  ORDER BY r.date DESC LIMIT 1),
                (SELECT r.rate FROM exchange_rates r
                  WHERE r.from_currency = COALESCE(entries.currency, entry_accounts.currency)
                    AND r.to_currency = :target_currency
                    AND r.date > entries.date
                  ORDER BY r.date ASC LIMIT 1),
                1::numeric
              )
            END AS rate
          ) fx ON TRUE
          WHERE entries.account_id = ANY(array[:account_ids]::uuid[])
            AND entries.date BETWEEN :start_date AND :end_date
            AND entries.excluded = false
          GROUP BY entries.date
        )
        SELECT
          b.date,
          b.value_close,
          b.value_open,
          b.market,
          b.revaluations,
          b.rate_missing,
          COALESCE(f.external_flow, 0) AS external_flow,
          COALESCE(f.income, 0) AS income,
          COALESCE(f.fees, 0) AS fees
        FROM balances_by_date b
        LEFT JOIN flows_by_date f ON f.date = b.date
        ORDER BY b.date
      SQL
    end

    def flow_class_sql
      @flow_class_sql ||= Portfolio::FlowClassifier.sql_case(
        entries: "entries", trades: "flow_trades",
        transactions: "flow_transactions", counterpart: "flow_counterpart_entries"
      )
    end

    def flow_class_joins
      @flow_class_joins ||= Portfolio::FlowClassifier.sql_joins(
        entries: "entries", trades: "flow_trades",
        transactions: "flow_transactions", counterpart: "flow_counterpart_entries",
        transfers: "flow_transfers"
      )
    end
end
