# The daily return series a set of accounts produced over a period, in the
# family's currency.
#
# Implements rows R1, R2, R6, R11 and R13 of docs/portfolio/returns-contract.md.
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
#
# CURRENCY DECOMPOSITION (R11). Each day's change in family-currency value is
# split exactly:
#
#   ΔV(t) = r(t-1)·ΔA(t)  +  A_end(t)·Δr(t)
#           \___local___/    \____fx_____/
#
# so every local component (flows, market, revaluations) is converted at the
# PREVIOUS day's rate and the fx term is the closing local balance times the
# rate change. That identity is what lets Portfolio::Drivers report a genuine
# `unexplained` residual instead of defining one away.
class Portfolio::DailyReturns
  # One day. `r` is nil until #returns computes it, so a caller reading rows
  # directly cannot mistake a raw component for a return.
  Row = Data.define(
    :date, :value_open, :value_close, :external_flow,
    :income, :fees, :market, :revaluations, :fx_effect,
    :rate_missing, :suppressed
  ) do
    def denominator
      value_open + external_flow
    end

    # R6: zero or negative denominators are suppressed rather than inverted.
    # `suppressed` is the answer to "does this day contribute a return?" and
    # covers more than the denominator -- a composition change is suppressed on
    # a perfectly positive one -- so it is what #returns must consult.
    def computable?
      !suppressed && denominator.positive?
    end

    def change
      value_close - value_open
    end

    # What the named components do not account for. Zero for an ordinary day;
    # non-zero when the portfolio's composition changed in a way no driver
    # describes -- an account entering or leaving the scope mid-period carries
    # its opening position in here rather than being silently attributed to
    # currency movement.
    def unexplained
      change - (external_flow + income - fees + market + revaluations + fx_effect)
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
      previous_active = nil

      raw_rows.map do |raw|
        value_close = decimal(raw["value_close"])

        # R1: the opening value is the previous day's close. On the first day of
        # the period there is no previous row, so the balance row's own
        # start_balance is used -- converted at the previous day's rate, which is
        # what makes it equal to the prior close by construction.
        value_open = previous_close || decimal(raw["value_open"])
        previous_close = value_close

        # A day an account leaves the scope is a COMPOSITION change, not a
        # return. value_close drops the account the moment it passes its
        # active_until_date while value_open still carries yesterday's close, so
        # the naive ratio reads as a loss of that account's whole balance -- and
        # with one account in the scope, exactly -100%, which #chain would then
        # multiply the entire period's TWR by zero.
        #
        # Suppressing it reuses R6's mechanism: the day stays in the series so
        # the calendar is unbroken, contributes a return of zero, and the value
        # difference is still visible in Row#unexplained, which is where a
        # composition change is documented to surface.
        active_accounts = raw["active_accounts"].to_i
        composition_changed = !previous_active.nil? && active_accounts < previous_active
        previous_active = active_accounts

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
          fx_effect: decimal(raw["fx_effect"]),
          rate_missing: raw["rate_missing"] == true,
          suppressed: !denominator.positive? || composition_changed
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

  # R13. True when an account that actually held a balance, or a flow that
  # feeds a figure, had no rate to the family currency. Scoped to contributing
  # accounts deliberately: an empty
  # foreign account a user has added but not yet synced contributes nothing to
  # any figure, and must not blank the whole portfolio's performance.
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
            COALESCE(SUM(lb.end_balance * lb.flows_factor * er.rate), 0) AS value_close,
            -- The opening level, which is only read for the FIRST day of the
            -- period (#rows carries the previous close afterwards).
            --
            -- A row dated on this day gives its own start_balance. A row
            -- CARRIED FORWARD from before the period is a level that was
            -- already reached, so its END balance is the opening value here.
            -- Reading its start_balance instead re-reported that historical
            -- day's change as a return on the period's first day, and left the
            -- difference in Row#unexplained.
            COALESCE(SUM(CASE WHEN lb.date < d.date THEN lb.end_balance ELSE lb.start_balance END
                         * lb.flows_factor * prev_er.rate), 0) AS value_open,
            -- Components come from a balance row dated EXACTLY on this day, not
            -- from the carried-forward one. LOCF is right for a level and wrong
            -- for a flow: re-reading yesterday's net_market_flows on every day
            -- of a gap would multiply the market driver by the gap's length.
            COALESCE(SUM(tb.net_market_flows * tb.flows_factor * prev_er.rate), 0) AS market,
            COALESCE(SUM((tb.cash_adjustments + tb.non_cash_adjustments)
                         * tb.flows_factor * prev_er.rate), 0) AS revaluations,
            -- The fx half of the identity in this class's header comment,
            -- measured rather than inferred: the closing local balance times the
            -- day's rate change. Zero when the account's currency is the
            -- family's, because both rates are then exactly 1.
            COALESCE(SUM(lb.end_balance * lb.flows_factor * (er.rate - prev_er.rate)), 0) AS fx_effect,
            BOOL_OR(lb.end_balance IS NOT NULL
                    AND sa.currency <> :target_currency
                    AND er.rate IS NULL) AS rate_missing,
            -- How many accounts are inside their active window on this day. A
            -- fall means an account reached its cut-off: value_close drops it
            -- while value_open still carries yesterday's close, which is a
            -- composition change and not a return. See #rows.
            COUNT(sa.id) AS active_accounts
          FROM dates d
          LEFT JOIN scoped_accounts sa
            ON sa.active_until_date IS NULL OR d.date <= sa.active_until_date
          LEFT JOIN LATERAL (
            SELECT b.date, b.end_balance, b.start_balance, b.flows_factor
            FROM balances b
            WHERE b.account_id = sa.id
              AND b.currency = sa.currency
              AND b.date <= d.date
            ORDER BY b.date DESC
            LIMIT 1
          ) lb ON TRUE
          LEFT JOIN LATERAL (
            SELECT b.net_market_flows, b.cash_adjustments, b.non_cash_adjustments, b.flows_factor
            FROM balances b
            WHERE b.account_id = sa.id
              AND b.currency = sa.currency
              AND b.date = d.date
            LIMIT 1
          ) tb ON TRUE
          LEFT JOIN LATERAL (
            SELECT #{rate_lookup('sa.currency', 'd.date')} AS rate
          ) er ON TRUE
          LEFT JOIN LATERAL (
            SELECT #{rate_lookup('sa.currency', "d.date - 1")} AS rate
          ) prev_er ON TRUE
          GROUP BY d.date
        ),
        flows_by_date AS (
          SELECT
            entries.date AS date,
            COALESCE(SUM(CASE WHEN #{flow_class_sql} IN ('external_inflow', 'external_outflow')
                              THEN -entries.amount * fx.rate ELSE 0 END), 0) AS external_flow,
            COALESCE(SUM(CASE WHEN #{flow_class_sql} = 'income'
                              THEN -entries.amount * fx.rate ELSE 0 END), 0) AS income,
            COALESCE(SUM(CASE WHEN #{flow_class_sql} = 'fee'
                              THEN  entries.amount * fx.rate ELSE 0 END), 0) AS fees,
            -- R13 applies to flows as it does to balances: a flow in a currency
            -- with no rate is flagged, never converted at parity. Only the
            -- classes that feed a figure count; an internal trade in an
            -- unconvertible currency moves nothing we sum.
            COALESCE(BOOL_OR(fx.rate IS NULL
                             AND #{flow_class_sql} IN ('external_inflow', 'external_outflow', 'income', 'fee')), false) AS flow_rate_missing
          FROM entries
          JOIN accounts entry_accounts ON entry_accounts.id = entries.account_id
          -- The same active-until window the balances use: a flow dated after
          -- an account stopped contributing value must not enter the
          -- denominator of a day that account is no longer part of.
          LEFT JOIN account_windows flow_windows ON flow_windows.account_id = entries.account_id
          #{flow_class_joins}
          -- Converted at the PREVIOUS day's rate, because a start-of-day flow
          -- joins the opening capital, which is itself valued at that rate.
          -- Mixing rates here is what would leave a residual in `unexplained`.
          -- NULL when the pair has no rate: the amount then drops out of every
          -- sum and flow_rate_missing says so.
          LEFT JOIN LATERAL (
            SELECT #{rate_lookup('COALESCE(entries.currency, entry_accounts.currency)', 'entries.date - 1')} AS rate
          ) fx ON TRUE
          WHERE entries.account_id = ANY(array[:account_ids]::uuid[])
            AND entries.date BETWEEN :start_date AND :end_date
            AND (flow_windows.active_until_date IS NULL OR entries.date <= flow_windows.active_until_date)
            -- COALESCE because entries.excluded is nullable: a bare
            -- `excluded = false` evaluates to NULL for such a row and drops it
            -- from the aggregation, while Portfolio::FlowClassifier treats the
            -- same row as a live flow. The two must agree.
            AND COALESCE(entries.excluded, false) = false
          GROUP BY entries.date
        )
        SELECT
          b.date,
          b.value_close,
          b.value_open,
          b.market,
          b.revaluations,
          b.fx_effect,
          (b.rate_missing OR COALESCE(f.flow_rate_missing, false)) AS rate_missing,
          b.active_accounts,
          COALESCE(f.external_flow, 0) AS external_flow,
          COALESCE(f.income, 0) AS income,
          COALESCE(f.fees, 0) AS fees
        FROM balances_by_date b
        LEFT JOIN flows_by_date f ON f.date = b.date
        ORDER BY b.date
      SQL
    end

    # Carry the last known rate forward, then fall back to the earliest one
    # ahead. Both halves matter: without the first a weekend converts at parity,
    # and without the second an account that predates the family's rate history
    # does. Returns NULL when the pair has no rate at all, which is what R13
    # surfaces.
    def rate_lookup(currency_expression, date_expression)
      <<~SQL.squish
        CASE
          WHEN #{currency_expression} = :target_currency THEN 1::numeric
          ELSE COALESCE(
            (SELECT r.rate FROM exchange_rates r
              WHERE r.from_currency = #{currency_expression}
                AND r.to_currency = :target_currency
                AND r.date <= #{date_expression}
              ORDER BY r.date DESC LIMIT 1),
            (SELECT r.rate FROM exchange_rates r
              WHERE r.from_currency = #{currency_expression}
                AND r.to_currency = :target_currency
                AND r.date > #{date_expression}
              ORDER BY r.date ASC LIMIT 1)
          )
        END
      SQL
    end

    # One classifier for both fragments, built on the scope this instance treats
    # as "inside". Its table aliases are fixed rather than passed in; nothing in
    # the queries above joins `trades` or `transactions` itself, so there is
    # nothing to collide with.
    def flow_classifier
      @flow_classifier ||= Portfolio::FlowClassifier.new(scope_account_ids: scope_account_ids)
    end

    def flow_class_sql
      @flow_class_sql ||= flow_classifier.sql_case
    end

    def flow_class_joins
      @flow_class_joins ||= flow_classifier.sql_joins
    end
end
