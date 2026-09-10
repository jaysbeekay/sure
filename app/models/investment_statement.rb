require "digest/md5"

class InvestmentStatement
  include Monetizable

  monetize :total_contributions, :total_dividends, :total_interest, :total_fees, :unrealized_gains

  attr_reader :family, :user

  def initialize(family, user: nil)
    @family = family
    @user = user || Current.user
  end

  # Get totals for a specific period
  def totals(period: Period.current_month)
    account_ids = investment_account_ids

    result = totals_query(account_ids: account_ids, date_range: period.date_range)

    PeriodTotals.new(
      contributions: Money.new(result[:contributions], family.currency),
      withdrawals: Money.new(result[:withdrawals], family.currency),
      dividends: Money.new(result[:dividends], family.currency),
      interest: Money.new(result[:interest], family.currency),
      fees: Money.new(result[:fees], family.currency),
      trades_count: result[:trades_count],
      currency: family.currency
    )
  end

  # Net contributions (contributions - withdrawals)
  def net_contributions(period: Period.current_month)
    t = totals(period: period)
    t.contributions - t.withdrawals
  end

  # Total portfolio value across all investment accounts
  def portfolio_value
    investment_accounts.sum { |a| convert_to_family_currency(a.balance, a.currency) }
  end

  def portfolio_value_money
    Money.new(portfolio_value, family.currency)
  end

  # Total cash in investment accounts
  def cash_balance
    investment_accounts.sum { |a| convert_to_family_currency(a.cash_balance, a.currency) }
  end

  def cash_balance_money
    Money.new(cash_balance, family.currency)
  end

  # Total holdings value
  def holdings_value
    portfolio_value - cash_balance
  end

  def holdings_value_money
    Money.new(holdings_value, family.currency)
  end

  # All current holdings across investment accounts. Holdings are returned in
  # their native currency; callers that aggregate across accounts must convert
  # to family currency via convert_to_family_currency.
  #
  # Memoized: top_holdings, allocation, unrealized_gains, unrealized_gains_trend,
  # and day_change each call this, so an unmemoized version ran the same
  # DISTINCT ON query up to 5x per dashboard/report request.
  def current_holdings
    @current_holdings ||= begin
      account_ids = investment_account_ids

      if account_ids.any?
        # Get the latest holding for each security per account
        Holding
          .where(account_id: account_ids)
          .where.not(qty: 0)
          .where(
            id: Holding
              .where(account_id: account_ids)
              .select("DISTINCT ON (holdings.account_id, holdings.security_id) holdings.id")
              .order(Arel.sql("holdings.account_id, holdings.security_id, holdings.date DESC"))
          )
          .includes(:security, :account)
      else
        Holding.none
      end
    end
  end

  # current_holdings as an Array, with the average-cost fallback for every
  # holding that has no stored cost basis computed in one query and handed
  # to the holding (Holding#preload_avg_cost), so unrealized_gains,
  # unrealized_gains_trend and the roll-up's trends do not run
  # Holding#calculate_avg_cost's two queries per holding. Memoized.
  def holdings_with_avg_costs
    @holdings_with_avg_costs ||= current_holdings.to_a.tap { |holdings| preload_avg_costs(holdings) }
  end

  # Top investments rolled up by security across accounts, ranked by
  # family-currency value. Weight is the security's share of the whole
  # portfolio, cash included -- the same number #allocation reports for it
  # (see #weight_denominator). Presence is gated on holdings totals, not
  # Account#balance, so a stale zero portfolio_value still surfaces real
  # positions.
  def top_holdings(limit: 5)
    rolled_up = holdings_rolled_up_by_security
    return [] if rolled_up.empty?

    total = weight_denominator(rolled_up)
    return [] if total.zero?

    # Rank/limit on value first; only then compute cost-basis trends for the
    # rows that will be rendered (avoids avg_cost/trade lookups for the rest).
    rolled_up
      .first(limit)
      .map do |security, value, holdings|
        HoldingAllocation.new(
          security: security,
          amount: Money.new(value, family.currency),
          weight: (value / total * 100).round(2),
          trend: combined_holding_trend(holdings)
        )
      end
  end

  # Portfolio allocation by security (rolled up across accounts), plus one
  # cash row for the part of the portfolio no holding accounts for, so the
  # weights sum to 100 and every security carries the same weight here as in
  # #top_holdings.
  #
  # The cash row is a residual (portfolio value minus holdings total), not
  # Account#cash_balance: when account balances are stale the residual is
  # zero and the row is omitted, whereas the reported cash balance could push
  # the sum past 100.
  def allocation
    rolled_up = holdings_rolled_up_by_security
    total = weight_denominator(rolled_up)
    return [] if total.zero?

    rows = rolled_up.map do |security, value, holdings|
      HoldingAllocation.new(
        security: security,
        amount: Money.new(value, family.currency),
        weight: (value / total * 100).round(2),
        trend: combined_holding_trend(holdings)
      )
    end

    cash = total - rolled_up.sum { |_, value, _| value }
    if cash.positive?
      rows << HoldingAllocation.new(
        security: nil,
        amount: Money.new(cash, family.currency),
        weight: (cash / total * 100).round(2),
        trend: nil
      )
    end

    rows
  end

  # Every security the family holds as one row, with its positions across
  # accounts, sorted for the portfolio hub's table. Built from
  # current_holdings and previous_holdings only: no per-row lookups, so the
  # query count does not grow with the number of holdings (P28, P30).
  #
  # Cost basis and unrealised P&L come from the stored cost_basis of every
  # position (locked, or positive); a position without one leaves both
  # blank and flags the row. Holding#avg_cost would fall back to a trades
  # query per position, which is what a table of every holding must avoid.
  #
  # sort: one of HOLDINGS_SORT_KEYS; dir: "asc" or "desc". Anything else is
  # the default (value desc), so the query string cannot raise.
  HOLDINGS_SORT_KEYS = %w[value weight return day_change name].freeze
  HOLDINGS_SORT_DIRECTIONS = %w[asc desc].freeze

  def holdings_table_rows(sort: "value", dir: "desc")
    rolled_up = holdings_rolled_up_by_security
    return [] if rolled_up.empty?

    total = weight_denominator(rolled_up)

    rows = rolled_up.map do |security, value, positions|
      build_holdings_table_row(security, value, positions, total)
    end

    sort_holdings_table_rows(rows, sort: sort, dir: dir)
  end

  # Allocation of the portfolio grouped by :account, :currency or :kind
  # (cash, crypto, standard), or by :security (the #allocation roll-up).
  # Weights within a grouping sum to 100 within rounding: the account
  # grouping is measured against the account balances, the currency and
  # kind groupings against the holdings plus each account's positive cash
  # balance, so a stale or negative cash balance never pushes a grouping
  # past 100. Segments are sorted by amount, largest first.
  ALLOCATION_GROUPINGS = %w[security account currency kind].freeze

  def allocation_by(by)
    case by.to_s
    when "account" then allocation_by_account
    when "currency" then allocation_by_currency
    when "kind" then allocation_by_kind
    else
      allocation.map do |row|
        AllocationSegment.new(id: row.cash? ? "cash" : row.security.id, name: row.name, amount: row.amount, weight: row.weight)
      end
    end
  end

  # Holdings the user should look at before trusting the figures: no cost
  # basis anywhere (Holding#avg_cost is nil: nothing stored and nothing the
  # trades can compute, by the same rules the holdings tab applies), a price
  # older than STALE_PRICE_AFTER_DAYS or no price at all, or a provider link
  # that is not healthy. Cash securities are never flagged. The cost bases
  # come from the batched preload and the price dates from one query, so
  # the list is bounded regardless of the number of holdings.
  STALE_PRICE_AFTER_DAYS = 5

  def data_quality_issues(as_of: Date.current)
    holdings = holdings_with_avg_costs
    return [] if holdings.empty?

    issues = []

    holdings.each do |holding|
      next if holding.security.cash?

      if holding.avg_cost.nil?
        issues << DataQualityIssue.new(kind: :missing_cost_basis, holding: holding, security: holding.security, detail: nil)
      end
    end

    holdings.map(&:security).uniq.each do |security|
      next if security.cash?

      latest = latest_price_dates[security.id]
      if latest.nil? || latest < as_of - STALE_PRICE_AFTER_DAYS
        issues << DataQualityIssue.new(kind: :stale_price, holding: nil, security: security, detail: latest)
      end

      status = security.provider_status
      issues << DataQualityIssue.new(kind: :provider, holding: nil, security: security, detail: status) unless status == :ok
    end

    issues.sort_by { |issue| [ DATA_QUALITY_KINDS.index(issue.kind), issue.security.ticker.to_s ] }
  end

  DATA_QUALITY_KINDS = %i[missing_cost_basis stale_price provider].freeze

  # Unrealized gains across all holdings, summed in family currency
  def unrealized_gains
    holdings_with_avg_costs.sum do |holding|
      trend = holding.trend
      trend ? convert_to_family_currency(trend.value, holding.currency) : 0
    end
  end

  # Total contributions (all time) - returns numeric for monetize
  def total_contributions
    all_time_totals.contributions&.amount || 0
  end

  # Total dividends (all time) - returns numeric for monetize
  def total_dividends
    all_time_totals.dividends&.amount || 0
  end

  # Total interest (all time) - returns numeric for monetize
  def total_interest
    all_time_totals.interest&.amount || 0
  end

  # Total fees (all time) - returns numeric for monetize
  def total_fees
    all_time_totals.fees&.amount || 0
  end

  def unrealized_gains_trend
    holdings = holdings_with_avg_costs
    return nil if holdings.empty?

    # Only include holdings with known cost basis in the calculation
    holdings_with_cost_basis = holdings.select(&:avg_cost)
    return nil if holdings_with_cost_basis.empty?

    current = holdings_with_cost_basis.sum do |h|
      convert_to_family_currency(h.amount, h.currency)
    end
    previous = holdings_with_cost_basis.sum do |h|
      convert_to_family_currency(h.qty * h.avg_cost.amount, h.currency)
    end

    Trend.new(
      current: Money.new(current, family.currency),
      previous: Money.new(previous, family.currency)
    )
  end

  def period_return_trend(period: Period.current_month)
    currency = family.currency
    account_ids = investment_account_ids
    return nil if account_ids.empty?

    absolute_return = ActiveRecord::Base.connection.select_value(
      ActiveRecord::Base.sanitize_sql_array([
        <<~SQL.squish,
          SELECT COALESCE(SUM(b.net_market_flows * COALESCE(er.rate, 1)), 0)
          FROM balances b
          JOIN accounts a ON a.id = b.account_id
          LEFT JOIN exchange_rates er ON (
            er.date = b.date
            AND er.from_currency = b.currency
            AND er.to_currency = :currency
          )
          WHERE a.id IN (:account_ids)
            AND a.family_id = :family_id
            AND a.status IN ('draft', 'active')
            AND b.date BETWEEN :start_date AND :end_date
        SQL
        {
          currency: currency,
          account_ids: account_ids,
          family_id: family.id,
          start_date: period.date_range.begin,
          end_date: period.date_range.end
        }
      ])
    ).to_d

    period_start = period.date_range.begin

    # Single query for all accounts' most recent pre-period balance (strict < to avoid
    # double-counting the first day's net_market_flows in both the denominator and absolute_return).
    # FX conversion is done in SQL (matching absolute_return) so balance rows whose currency
    # differs from the account's current currency (e.g. after a currency change) are still picked up.
    start_value = ActiveRecord::Base.connection.select_value(
      ActiveRecord::Base.sanitize_sql_array([
        <<~SQL.squish,
          SELECT COALESCE(SUM(b.end_balance * COALESCE(er.rate, 1)), 0)
          FROM accounts a
          INNER JOIN balances b ON b.account_id = a.id
          LEFT JOIN exchange_rates er ON (
            er.date = :period_start
            AND er.from_currency = b.currency
            AND er.to_currency = :currency
          )
          INNER JOIN (
            SELECT b2.account_id, MAX(b2.date) AS max_date
            FROM balances b2
            WHERE b2.account_id IN (:account_ids)
              AND b2.date < :period_start
            GROUP BY b2.account_id
          ) latest ON latest.account_id = b.account_id AND b.date = latest.max_date
          WHERE a.id IN (:account_ids)
            AND a.family_id = :family_id
            AND a.status IN ('draft', 'active')
        SQL
        { account_ids: account_ids, period_start: period_start, family_id: family.id, currency: currency }
      ])
    ).to_d

    return nil if start_value.zero?

    Trend.new(
      current: Money.new(start_value + absolute_return, currency),
      previous: Money.new(start_value, currency)
    )
  end

  # Portfolio value (cash + holdings) over the period, in family currency.
  #
  # Charted from the *historical* account scope, so a disabled broker keeps its
  # history up to its cut-off date. The last point therefore diverges from
  # #portfolio_value (visible accounts only) whenever a disabled account still
  # carries a non-zero balance. See HistoricalScope for the rationale.
  def value_series(period: Period.last_30_days)
    fetch_series(:value, period) { |builder| builder.balance_series }
  end

  # Holdings-only value (portfolio value minus cash) over the period.
  def holdings_value_series(period: Period.last_30_days)
    fetch_series(:holdings_value, period) { |builder| builder.holdings_balance_series }
  end

  # Unrealized gains (market value minus cost basis) over the period.
  def gains_series(period: Period.last_30_days)
    fetch_series(:gains, period) { |builder| builder.gains_series }
  end

  def historical_scope
    @historical_scope ||= HistoricalScope.new(family, user: user)
  end

  # The snapshot before each current holding, keyed by [account_id,
  # security_id]: the latest row for the same account, security and currency
  # dated before the current row, which is what Holding#day_change compares
  # against. One query for every holding rather than one per holding, so a
  # page that lists every position does not issue a query per row. Memoized
  # like current_holdings.
  def previous_holdings
    @previous_holdings ||= begin
      current_ids = current_holdings.map(&:id)

      if current_ids.any?
        Holding
          .joins(ActiveRecord::Base.sanitize_sql_array([
            <<~SQL.squish,
              JOIN holdings current_holdings
                ON current_holdings.id IN (:current_ids)
                AND current_holdings.account_id = holdings.account_id
                AND current_holdings.security_id = holdings.security_id
                AND current_holdings.currency = holdings.currency
                AND holdings.date < current_holdings.date
            SQL
            { current_ids: current_ids }
          ]))
          .select("DISTINCT ON (holdings.account_id, holdings.security_id) holdings.*")
          .order(Arel.sql("holdings.account_id, holdings.security_id, holdings.date DESC"))
          .index_by { |holding| [ holding.account_id, holding.security_id ] }
      else
        {}
      end
    end
  end

  # Day change for one current holding against its previous snapshot, in the
  # holding's currency, or nil without a prior snapshot. Same result as
  # Holding#day_change, without its per-holding query.
  def holding_day_change(holding)
    return nil unless holding.amount_money

    previous = previous_holdings[[ holding.account_id, holding.security_id ]]
    return nil unless previous&.amount_money

    Trend.new(current: holding.amount_money, previous: previous.amount_money)
  end

  # Day change across portfolio, summed in family currency
  def day_change
    changes = current_holdings.to_a.filter_map do |h|
      t = holding_day_change(h)
      next nil unless t
      [
        convert_to_family_currency(t.current.amount, h.currency),
        convert_to_family_currency(t.previous.amount, h.currency)
      ]
    end

    return nil if changes.empty?

    Trend.new(
      current: Money.new(changes.sum { |c, _| c }, family.currency),
      previous: Money.new(changes.sum { |_, p| p }, family.currency)
    )
  end

  # Investment accounts
  def investment_accounts
    @investment_accounts ||= begin
      scope = family.accounts.visible.included_in_reports.where(accountable_type: %w[Investment Crypto])
      scope = scope.included_in_finances_for(user) if user
      scope
    end
  end

  private
    # Two layers of caching, mirroring BalanceSheet::NetWorthSeriesBuilder:
    # Rails.cache across requests, plus a per-instance memo so a single
    # dashboard render that asks for the same series twice runs one query.
    #
    # Every series is trimmed to the date all linked accounts in the scope
    # have history for, as the account charts are: the balance rows before a
    # broker's first snapshot are zeros, and charting them shows a portfolio
    # that appears from nothing on the day the connection was made.
    def fetch_series(kind, period)
      @series_cache ||= {}
      @series_cache[[ kind, period.start_date, period.end_date ]] ||= Rails.cache.fetch(series_cache_key(kind, period)) do
        Balance::LinkedInvestmentSeriesNormalizer.trim_to_supported_history(
          yield(series_builder(period)),
          account_ids: historical_scope.account_ids
        )
      end
    end

    def series_builder(period)
      Balance::ChartSeriesBuilder.new(
        account_ids: historical_scope.account_ids,
        account_active_until_dates: historical_scope.active_until_dates,
        currency: family.currency,
        period: period,
        favorable_direction: "up"
      )
    end

    # Beyond the family key (sync time and accounts.updated_at), the key
    # carries a version for each table the series reads that can change
    # without a sync or an account write:
    #
    # - shares (every kind): revoking a share deletes a row, which changes
    #   neither maximum(:updated_at) nor accounts.updated_at, and a key built
    #   from those alone would keep serving a series that still counts the
    #   revoked account.
    # - holdings (gains only): the gains series reads holdings.cost_basis,
    #   which a manual cost-basis edit, an unlock or a security remap
    #   rewrites in place. The value series read balances, which only a
    #   sync rewrites, so they do not pay for the extra queries.
    def series_cache_key(kind, period)
      key = [
        "investment_statement_#{kind}_series",
        user&.id,
        shares_version,
        (holdings_version if kind == :gains),
        period.start_date,
        period.end_date
      ].compact.join("_")

      family.build_cache_key(key, invalidate_on_data_updates: true)
    end

    # Memoized: one instance builds a key per series kind it is asked for,
    # and the versions need not be re-queried between them.
    def shares_version
      return nil unless user

      @shares_version ||= begin
        shares = AccountShare.where(user: user)
        "#{shares.count}-#{shares.maximum(:updated_at)&.to_f || 0}"
      end
    end

    # Count plus latest timestamp over the holdings the series can read, so a
    # cost-basis edit, unlock or remap (rows rewritten in place) and a
    # deletion (a row gone, timestamps unchanged) each move the gains key.
    def holdings_version
      @holdings_version ||= begin
        holdings = Holding.where(account_id: historical_scope.account_ids)
        "#{holdings.count}-#{holdings.maximum(:updated_at)&.to_f || 0}"
      end
    end

    # Today's rates for every currency present on the family's investment
    # accounts and their holdings. Mirrors BalanceSheet::AccountTotals#exchange_rates.
    def exchange_rates
      @exchange_rates ||= begin
        account_currencies = investment_accounts.map(&:currency)
        holding_currencies = Holding.where(account_id: investment_account_ids).distinct.pluck(:currency)
        foreign = (account_currencies + holding_currencies)
                    .compact
                    .uniq
                    .reject { |c| c == family.currency }
        ExchangeRate.rates_for(foreign, to: family.currency, date: Date.current)
      end
    end

    # Unwrap Money first because this codebase's Money (lib/money.rb) ignores
    # the currency arg of `Money.new` when the payload is already a Money, and
    # `Money * numeric` preserves the source currency — so multiplying a
    # foreign-currency Money by a rate would FX-scale the amount but keep the
    # wrong currency label, corrupting downstream sums.
    def convert_to_family_currency(amount, from_currency)
      return amount if amount.nil?
      numeric = amount.is_a?(Money) ? amount.amount : amount
      return numeric if from_currency == family.currency
      rate = exchange_rates[from_currency] || 1
      numeric * rate
    end

    def all_time_totals
      @all_time_totals ||= totals(period: Period.all_time)
    end

    # fees is stated separately from contributions and withdrawals: a buy's
    # contribution is the cost of the securities and its fee is in fees, so
    # contributions + fees is the cash that left for a purchase.
    PeriodTotals = Data.define(:contributions, :withdrawals, :dividends, :interest, :fees, :trades_count, :currency) do
      def net_flow
        contributions - withdrawals
      end

      def total_income
        dividends + interest
      end
    end

    # One row of #top_holdings / #allocation. Duck-types the Holding readers
    # the dashboard, Reports and print views call (ticker, name, security,
    # weight, amount_money, trend). `security` is nil only for the cash row
    # #allocation appends.
    HoldingsTableRow = Data.define(
      :security, :positions, :accounts_count, :qty, :avg_cost, :amount, :weight,
      :unrealized, :day_change, :missing_cost_basis
    ) do
      def ticker = security.ticker
      def name = security.name.presence || ticker
      def amount_money = amount
    end

    AllocationSegment = Data.define(:id, :name, :amount, :weight)

    DataQualityIssue = Data.define(:kind, :holding, :security, :detail)

    HoldingAllocation = Data.define(:security, :amount, :weight, :trend) do
      def cash? = security.nil?
      def ticker = cash? ? CASH_TICKER : security.ticker
      def name = cash? ? I18n.t("models.investment_statement.cash") : (security.name.presence || ticker)
      def amount_money = amount
    end

    CASH_TICKER = "CASH".freeze

    # The one denominator every weight is measured against: the larger of the
    # live portfolio value (account balances, cash included) and the holdings
    # total.
    #
    # Portfolio value is the right denominator -- a security's weight is its
    # share of everything the user holds, cash included -- but it is
    # Account#balance, which can lag the holdings (stale zero after a sync)
    # or fall below them (negative cash from margin or an unsettled buy).
    # Dividing by it in either case reports a weight over 100. The holdings
    # total is a floor that keeps every weight at or below 100; when it wins,
    # the residual cash is zero or negative and #allocation shows no cash row.
    def build_holdings_table_row(security, value, positions, total)
      qty = positions.sum(&:qty)

      # Same rule as combined_holding_trend and the unrealised-gains KPI
      # (P28): the return covers the positions whose cost basis is known, and
      # a position is known when Holding#avg_cost answers -- which includes
      # the trade-history fallback, preloaded for every holding by
      # holdings_with_avg_costs. Reading `cost_basis` directly instead would
      # hide a return on this table that the KPI above it counts, for the
      # same security, on the same page.
      known = positions.select(&:avg_cost)
      missing_cost_basis = known.size < positions.size

      cost = nil
      unrealized = nil
      known_qty = known.sum(&:qty)
      if known.any?
        cost = known.sum { |holding| convert_to_family_currency(holding.qty * holding.avg_cost.amount, holding.currency) }
        known_value = known.sum { |holding| convert_to_family_currency(holding.amount, holding.currency) }
        unrealized = Trend.new(current: Money.new(known_value, family.currency), previous: Money.new(cost, family.currency))
      end

      day_changes = positions.filter_map do |holding|
        trend = holding_day_change(holding)
        next unless trend
        [ convert_to_family_currency(trend.current.amount, holding.currency), convert_to_family_currency(trend.previous.amount, holding.currency) ]
      end
      day_change = if day_changes.any?
        Trend.new(
          current: Money.new(day_changes.sum(&:first), family.currency),
          previous: Money.new(day_changes.sum(&:last), family.currency)
        )
      end

      HoldingsTableRow.new(
        security: security,
        positions: positions,
        accounts_count: positions.map(&:account_id).uniq.size,
        qty: qty,
        avg_cost: (cost && known_qty.positive?) ? Money.new(cost / known_qty, family.currency) : nil,
        amount: Money.new(value, family.currency),
        weight: total.zero? ? 0 : (value / total * 100).round(2),
        unrealized: unrealized,
        day_change: day_change,
        missing_cost_basis: missing_cost_basis
      )
    end

    def sort_holdings_table_rows(rows, sort:, dir:)
      sort = HOLDINGS_SORT_KEYS.include?(sort.to_s) ? sort.to_s : "value"
      dir = HOLDINGS_SORT_DIRECTIONS.include?(dir.to_s) ? dir.to_s : "desc"

      # Rows without the sorted figure go last whichever direction is asked.
      present, absent = rows.partition { |row| sort_key_present?(row, sort) }
      present = present.sort_by { |row| sort_value(row, sort) }
      present.reverse! if dir == "desc"
      present + absent
    end

    def sort_value(row, sort)
      case sort
      when "value" then row.amount.amount
      when "weight" then row.weight
      when "return" then row.unrealized.value.amount
      when "day_change" then row.day_change.value.amount
      when "name" then row.name.downcase
      end
    end

    def sort_key_present?(row, sort)
      case sort
      when "return" then row.unrealized.present?
      when "day_change" then row.day_change.present?
      else true
      end
    end

    # The rule Holding#avg_cost applies to a stored basis before it falls
    # back to trades: locked values are trusted even at zero, unlocked ones
    # only when positive.
    def stored_cost_basis?(holding)
      holding.cost_basis.present? && (holding.cost_basis_locked? || holding.cost_basis.positive?)
    end

    # One query for the fallback Holding#calculate_avg_cost would run per
    # holding: the weighted average of buy trades on or before the holding's
    # date, converted to the account currency at each trade's date, unknown
    # (nil) when any of those trades is a Transfer or when there are none.
    # The SQL mirrors calculate_avg_cost line for line; the parity test in
    # InvestmentStatementTest holds them together.
    def preload_avg_costs(holdings)
      pending = holdings.reject { |holding| stored_cost_basis?(holding) }
      return if pending.empty?

      rows = ActiveRecord::Base.connection.select_all(
        ActiveRecord::Base.sanitize_sql_array([
          <<~SQL.squish,
            SELECT cur.id AS holding_id,
              BOOL_OR(trades.investment_activity_label = :transfer_label) AS has_transfer,
              SUM(CASE WHEN trades.investment_activity_label IS DISTINCT FROM :transfer_label
                THEN trades.price * trades.qty * COALESCE(exchange_rates.rate, 1) ELSE 0 END) AS total_cost,
              SUM(CASE WHEN trades.investment_activity_label IS DISTINCT FROM :transfer_label
                THEN trades.qty ELSE 0 END) AS total_qty
            FROM holdings cur
            JOIN accounts ON accounts.id = cur.account_id
            JOIN entries ON entries.account_id = cur.account_id
              AND entries.entryable_type = 'Trade'
              AND entries.date <= cur.date
            JOIN trades ON trades.id = entries.entryable_id
              AND trades.security_id = cur.security_id
              AND trades.qty > 0
            LEFT JOIN exchange_rates ON (
              exchange_rates.date = entries.date
              AND exchange_rates.from_currency = trades.currency
              AND exchange_rates.to_currency = accounts.currency
            )
            WHERE cur.id IN (:holding_ids)
            GROUP BY cur.id
          SQL
          { holding_ids: pending.map(&:id), transfer_label: Trade::TRANSFER_LABEL }
        ])
      ).index_by { |row| row["holding_id"] }

      pending.each do |holding|
        row = rows[holding.id]
        total_qty = row && row["total_qty"]&.to_d
        value = if row.nil? || row["has_transfer"] || total_qty.nil? || total_qty <= 0
          nil
        else
          Money.new(row["total_cost"].to_d / total_qty, holding.currency)
        end
        holding.preload_avg_cost(value)
      end
    end

    def latest_price_dates
      @latest_price_dates ||= Security::Price
        .where(security_id: current_holdings.map(&:security_id).uniq)
        .group(:security_id)
        .maximum(:date)
    end

    def allocation_by_account
      segments = investment_accounts.map do |account|
        [ account.id, account.name, convert_to_family_currency(account.balance, account.currency) ]
      end
      build_segments(segments)
    end

    def allocation_by_currency
      grouped = Hash.new(0)
      current_holdings.each { |holding| grouped[holding.currency] += convert_to_family_currency(holding.amount, holding.currency) }
      investment_accounts.each do |account|
        cash = account.cash_balance.to_d
        grouped[account.currency] += convert_to_family_currency(cash, account.currency) if cash.positive?
      end
      build_segments(grouped.map { |currency, value| [ currency, currency, value ] })
    end

    def allocation_by_kind
      grouped = Hash.new(0)
      current_holdings.each do |holding|
        kind = if holding.security.cash? then "cash"
        elsif holding.security.crypto? then "crypto"
        else "standard"
        end
        grouped[kind] += convert_to_family_currency(holding.amount, holding.currency)
      end
      investment_accounts.each do |account|
        cash = account.cash_balance.to_d
        grouped["cash"] += convert_to_family_currency(cash, account.currency) if cash.positive?
      end
      build_segments(grouped.map { |kind, value| [ kind, kind, value ] })
    end

    def build_segments(rows)
      rows = rows.reject { |_, _, value| value.nil? || value <= 0 }
      total = rows.sum { |_, _, value| value }
      return [] if total.zero?

      rows
        .sort_by { |_, _, value| -value }
        .map do |id, name, value|
          AllocationSegment.new(id: id.to_s, name: name, amount: Money.new(value, family.currency), weight: (value / total * 100).round(2))
        end
    end

    def weight_denominator(rolled_up)
      holdings_total = rolled_up.sum { |_, value, _| value }
      [ portfolio_value, holdings_total ].max
    end

    # Groups current holdings by security and sums family-currency value.
    # Returns [[security, value, holdings], ...] sorted by value descending.
    # Callers that need return trends should call combined_holding_trend only
    # for rows they will render (e.g. after top_holdings applies its limit).
    #
    # A security whose holdings do not sum to a positive value is left out
    # rather than listed at weight 0 or at a negative weight (methodology
    # P27). Zero is a position with no price yet. Negative is corrupt data:
    # Holding validates qty, price and amount as non-negative, but
    # Holding::Materializer writes through upsert_all, which does not run
    # validations, so an over-sell can land one. Keeping it out is what makes
    # the weight denominator a real ceiling -- with a negative row in the sum,
    # holdings_total falls below the largest row and its weight goes over 100.
    #
    # Memoized: top_holdings and allocation both start here, and the
    # grouping and FX conversion need only run once per instance.
    def holdings_rolled_up_by_security
      @holdings_rolled_up_by_security ||= holdings_with_avg_costs
        .group_by(&:security_id)
        .filter_map do |_security_id, holdings|
          security = holdings.first.security
          value = holdings.sum { |h| convert_to_family_currency(h.amount, h.currency) }
          next unless value.positive?

          [ security, value, holdings ]
        end
        .sort_by { |_, value, _| -value }
    end

    # The return of a rolled-up row is measured over the holdings of the
    # security whose cost basis is known (Holding#trend is nil otherwise):
    # current value and cost of those holdings only, in family currency. The
    # row's amount still counts every holding. With no known cost basis the
    # trend is nil and readers show no return (methodology P28).
    def combined_holding_trend(holdings)
      currents = []
      previouses = []

      holdings.each do |holding|
        trend = holding.trend
        next unless trend

        currents << convert_to_family_currency(trend.current, holding.currency)
        previouses << convert_to_family_currency(trend.previous, holding.currency)
      end

      return nil if currents.empty?

      Trend.new(
        current: Money.new(currents.sum, family.currency),
        previous: Money.new(previouses.sum, family.currency)
      )
    end

    def investment_account_ids
      @investment_account_ids ||= investment_accounts.pluck(:id)
    end

    def totals_query(account_ids:, date_range:)
      if account_ids.empty?
        return Totals.new(family, account_ids: account_ids, date_range: date_range).call
      end

      account_ids_hash = Digest::MD5.hexdigest(account_ids.sort.join(","))

      Rails.cache.fetch([
        # Bumped when the aggregation's meaning changes (v2: real income
        # totals; v3: fees, and contributions net of reported fees) so a
        # deploy never serves the previous shape from Redis.
        "investment_statement", "totals_query/v3", family.id, user&.id,
        account_ids_hash, date_range.begin, date_range.end, family.entries_cache_version
      ]) { Totals.new(family, account_ids: account_ids, date_range: date_range).call }
    end

    def monetizable_currency
      family.currency
    end
end
