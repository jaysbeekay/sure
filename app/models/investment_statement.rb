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
  # query count does not grow with the number of holdings (P28, P31).
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
  ALLOCATION_GROUPINGS = %w[security asset_class asset_sub_class sector region tag account currency kind].freeze

  # The bucket a holding falls into when the column it is grouped by is empty.
  # It is a real segment, not a gap: `Portfolio::SectionRegistry` hides the
  # whole allocation section when a grouping returns no segments, so without
  # this a portfolio of unclassified securities would lose the section rather
  # than be told it has nothing classified yet.
  UNCLASSIFIED = "unclassified".freeze

  # One level down from a classification segment, for the drill-down.
  #
  # Only the asset-class ladder has a natural child level: sub-classes inside a
  # class, then the holdings inside a sub-class. Sector, region, currency and
  # account do not nest -- a sector has no sub-sector here -- so they return
  # nothing and render flat, rather than having a level invented for them.
  #
  # **Look-through nests too, through the same rows the parents come from.**
  # #201 shipped this flat, because the parents were filed by what a fund HOLDS
  # while every method below read the fund's OWN columns -- a fund classified
  # equity/etf holding 60% shares and 40% bonds showed an `equity` parent at 60%
  # opening onto an `etf` child at 100%, and a `fixed_income` parent with no
  # children. Two answers for the same money on one screen.
  #
  # #217 settled the product question (show the constituents) and the fix is to
  # slice ONE row set at every level rather than derive each level separately:
  # see `look_through_rows`. The parent and the child then cannot disagree,
  # because they are two groupings of the same rows.
  def allocation_children(by, bucket, look_through: false)
    case by.to_s
    when "asset_class" then allocation_sub_classes_within(bucket, look_through: look_through)
    when "asset_sub_class" then allocation_holdings_within(:asset_sub_class, bucket, "cash", look_through: look_through)
    else []
    end
  end

  # Whether anything in the portfolio can BE looked through. Asked by the
  # section registry so the toggle is not offered to someone holding no funds,
  # where it would be a control that visibly does nothing.
  # Does the portfolio hold a fund look-through could actually expand?
  #
  # Existence of constituent ROWS is not enough. `Security#look_through_weights`
  # divides by the sum of the non-nil weights and returns {} when that sum is
  # zero, so a fund whose constituents carry nil or zero weights expands to
  # nothing and the toggle renders as a control that visibly does nothing
  # (raised by cubic on #201).
  #
  # The condition mirrors that method's own rule rather than approximating it:
  # non-nil weights, summed PER SECURITY, greater than zero. A row-level
  # `weight > 0` would disagree with it for a fund whose weights cancel out.
  #
  # The holding has to be worth something too. `build_segments` drops every
  # zero-value row, so a fund held at zero contributes nothing to any segment
  # however well-weighted its constituents are -- and if another holding keeps
  # the section on screen, the toggle appeared beside it and did nothing. Same
  # defect as the zero-weight case above, reached from the value side rather
  # than the weight side (CodeRabbit, #201).
  def holds_any_fund_constituents?
    Security::Constituent
      .where(security_id: contributing_security_ids)
      .where.not(weight: nil)
      .group(:security_id)
      .having("SUM(weight) > 0")
      .pick(:security_id)
      .present?
  end

  # `look_through` expands a fund into what it actually holds. It applies only to
  # the classification axes: account, currency and kind are properties of the
  # POSITION, not of the instrument, and a fund's constituents do not have their
  # own account. Grouping by security with look-through would also be wrong -- the
  # security IS the fund.
  def allocation_by(by, look_through: false)
    case by.to_s
    when "account" then allocation_by_account
    when "currency" then allocation_by_currency
    when "kind" then allocation_by_kind
    when "tag" then allocation_by_tag
    when "asset_class" then allocation_by_classification(:asset_class, cash_bucket: "liquidity", look_through: look_through)
    when "asset_sub_class" then allocation_by_classification(:asset_sub_class, cash_bucket: "cash", look_through: look_through)
    when "sector" then allocation_by_classification(:sector, look_through: look_through)
    when "region" then allocation_by_classification(:region, look_through: look_through)
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

    issues.concat(ambiguous_constituent_issues)

    issues.sort_by { |issue| [ DATA_QUALITY_KINDS.index(issue.kind), issue.security.ticker.to_s ] }
  end

  DATA_QUALITY_KINDS = %i[missing_cost_basis stale_price provider ambiguous_constituent].freeze

  # Funds holding a constituent whose ticker exists on more than one exchange,
  # where the family's own positions do not say which listing is meant (#214).
  #
  # Computed HERE rather than as a side effect of the look-through, so the row
  # does not depend on which portfolio sections happened to render first. The
  # resolver is memoised, so a look-through later in the same request pays
  # nothing for this.
  #
  # Gated on `holds_any_fund_constituents?`, which is one cheap query: a
  # portfolio with no expandable fund does no work at all, rather than every
  # portfolio page paying for a feature most of them do not use.
  def ambiguous_constituent_issues
    return [] if constituent_rows_by_security.empty?

    ambiguous = ambiguous_constituent_tickers
    return [] if ambiguous.empty?

    # By SECURITY, not by holding, and `holding: nil` -- the same shape the
    # `stale_price` and `provider` kinds above already use, and for the same
    # reason. `current_holdings` returns a row per (account, security), so a
    # family holding one fund in two accounts got two identical rows naming the
    # same fund and the same tickers. The ambiguity is a property of the fund's
    # constituents, resolved once for the whole portfolio; it has nothing to do
    # with which account the position sits in (CodeRabbit, #220).
    current_holdings.map(&:security).uniq.filter_map do |security|
      weights = constituent_weights_for(security)
      next if weights.empty?

      # `uniq` after upcasing: a fund reporting both "dual" and "DUAL" is one
      # ambiguous ticker, not two.
      unresolved = weights.keys.map { |t| t.to_s.upcase }.uniq.select { |ticker| ambiguous.include?(ticker) }
      next if unresolved.empty?

      DataQualityIssue.new(
        kind: :ambiguous_constituent,
        holding: nil,
        security: security,
        detail: unresolved.sort
      )
    end
  end

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

  # R13: a figure whose inputs cannot all be converted is withheld, never
  # converted at parity. An account whose balance currency has no rate to the
  # family currency ANYWHERE is dropped from both legs -- the flows and the
  # start value -- so the numerator and the denominator are measured over the
  # same set. Dropping it from one alone would report a return on a basis that
  # does not include it.
  #
  # The caller surfaces what was dropped through
  # #period_return_unconvertible_count, so the card can say the figure is
  # partial rather than presenting it as whole.
  # How many investment accounts #period_return_trend had to leave out, so the
  # card can disclose a partial figure rather than present it as whole. Zero
  # when everything converts, which is the ordinary case.
  def period_return_unconvertible_count(period: Period.current_month)
    period_return_unconvertible_account_ids(period).length
  end

  def period_return_trend(period: Period.current_month)
    currency = family.currency
    account_ids = investment_account_ids - period_return_unconvertible_account_ids(period)
    return nil if account_ids.empty?

    absolute_return = ActiveRecord::Base.connection.select_value(
      ActiveRecord::Base.sanitize_sql_array([
        <<~SQL.squish,
          SELECT COALESCE(SUM(b.net_market_flows * (#{exchange_rate_lookup('b.currency', 'b.date')})), 0)
          FROM balances b
          JOIN accounts a ON a.id = b.account_id
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
          SELECT COALESCE(SUM(b.end_balance * (#{exchange_rate_lookup('b.currency', ':period_start')})), 0)
          FROM accounts a
          INNER JOIN balances b ON b.account_id = a.id
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

  # Time- and money-weighted returns, volatility, drawdown and the drivers
  # breakdown for the family's investment accounts over `period`.
  #
  # See docs/portfolio/returns-contract.md, which is normative for every figure
  # this returns. The engine is read-only and cached, so it is safe from a GET.
  #
  # ACCOUNT SCOPE. The *historical* scope, matching #value_series and the
  # net-worth series: a closed or disabled account keeps its history up to its
  # cut-off date instead of vanishing from the return. #119's decision D2 is
  # settled this way, so returns and the value chart are measured over the same
  # accounts -- the alternative let a family that closed a large account see a
  # return history contradicting its own chart.
  #
  # `active_until_dates` is what carries the cut-off: Portfolio::DailyReturns
  # stops counting an account's balances and flows after its date, so the
  # account contributes the days it was real and nothing after.
  #
  # The default period is the family's month, which starts on its custom
  # month-start day when it has one (`Period.current_month_for`), as the
  # period picker's default does.
  def performance(period: Period.current_month_for(family))
    Portfolio::Performance.new(
      family: family,
      account_ids: historical_scope.account_ids,
      period: period,
      user: user,
      active_until_dates: historical_scope.active_until_dates
    )
  end

  # What return method each account's data can support, keyed by account id.
  # Callers must not quote a figure an account's scope does not support -- see
  # contract rows R15 and R16.
  #
  # Same historical scope as #performance, and for the same reason: an account
  # whose history is inside the aggregate return must have a scope a reader can
  # look up, or the per-account breakdown silently omits a contributor to the
  # total it sits beside.
  def return_scopes(period: Period.current_month_for(family))
    Portfolio::ReturnScope.resolve_all(accounts: historical_scope.accounts, period: period)
  end

  # Realised profit and loss over the period, by the month it was crystallised.
  #
  # Same historical scope, and for the same reason #performance gives: a
  # realised-P&L timeline printed beside a return figure must be measured over
  # the same accounts, or the two quietly describe different portfolios.
  def realized_gains(period: Period.current_month_for(family))
    Portfolio::RealizedGains.new(
      accounts: historical_scope.accounts,
      period: period,
      currency: family.currency,
      active_until_dates: historical_scope.active_until_dates
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
    # The securities behind holdings that actually contribute value, measured
    # the way `build_segments` measures them, so the eligibility check and the
    # segments cannot disagree about what counts as present.
    def contributing_security_ids
      current_holdings
        .select { |holding| convert_to_family_currency(holding.amount, holding.currency).to_d.positive? }
        .map(&:security_id)
        .uniq
    end

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
    # - holdings (every kind): the gains series reads holdings.cost_basis,
    #   which a manual cost-basis edit, an unlock or a security remap
    #   rewrites in place. Every series is also trimmed to the supported
    #   history start (P30), which provider holdings' dates and securities
    #   decide, so deleting or remapping a holding can move the value and
    #   holdings-value charts' first date without a sync.
    def series_cache_key(kind, period)
      key = [
        "investment_statement_#{kind}_series",
        user&.id,
        shares_version,
        holdings_version,
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
    # deletion (a row gone, timestamps unchanged) each move every series key.
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

    # fees is stated separately from contributions and withdrawals rather than
    # subtracted out of them. Whether a contribution already contains its fee
    # is a property of the writer -- Trade::CreateForm and Binance P2P fold it
    # into entries.amount, Kraken and Binance spot do not -- so the two are not
    # additive for every provider. P21 states this; the reasoning is in
    # InvestmentStatement::Totals.
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

    # Builds one rolled-up row of the holdings table for `security`: the summed
    # quantity across `positions`, its average cost and unrealised return over
    # the positions whose basis is known, and its weight against the caller's
    # `total` -- which is chosen by #weight_denominator, not here.
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

    # The batch itself lives on Holding, because Portfolio::RealizedGains needs
    # the same one. The parity test that holds the SQL to
    # Holding#calculate_avg_cost stays here, where it was written.
    def preload_avg_costs(holdings)
      Holding.preload_avg_costs(holdings)
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

    # The shape R13 prescribes, and the same one `Portfolio::DailyReturns`
    # uses: the most recent rate on or before the date, else the earliest rate
    # after it, else NULL. Never 1. The identity shortcut keeps a family's own
    # currency off `exchange_rates` entirely.
    def exchange_rate_lookup(currency_expression, date_expression)
      <<~SQL.squish
        CASE
          WHEN #{currency_expression} = :currency THEN 1::numeric
          ELSE COALESCE(
            (SELECT r.rate FROM exchange_rates r
              WHERE r.from_currency = #{currency_expression}
                AND r.to_currency = :currency
                AND r.date <= #{date_expression}
              ORDER BY r.date DESC LIMIT 1),
            (SELECT r.rate FROM exchange_rates r
              WHERE r.from_currency = #{currency_expression}
                AND r.to_currency = :currency
                AND r.date > #{date_expression}
              ORDER BY r.date ASC LIMIT 1)
          )
        END
      SQL
    end

    # Accounts #period_return_trend cannot include, because a balance row of
    # theirs is denominated in a currency with no rate to the family currency
    # at all.
    #
    # "At all" is the right test, not "on that date": the lookup above falls
    # back to the earliest rate AFTER the date, so a pair with any rate row
    # anywhere resolves. A pair with none can never resolve, on any date.
    #
    # Judged per ACCOUNT rather than per row, because the two legs select rows
    # differently -- the flows leg takes every row in the period, the start
    # value leg takes the last row before it. Dropping rows independently would
    # let an account contribute flows without contributing the start value they
    # are measured against.
    #
    # The row set is deliberately WIDER than the rows those two legs read: every
    # balance up to the period end, not just the in-period rows plus the last
    # pre-period one. An account that held an unconvertible currency years ago
    # is therefore excluded even though both legs could convert everything they
    # actually read, and the card says so.
    #
    # That is the conservative side to err on, and it is a deliberate choice
    # rather than an oversight: the alternative is to decide per period which
    # historical rows "count", and a balance the account still carries forward
    # is exactly the kind of row that looks irrelevant until it is not.
    # Narrowing it is tracked rather than done here, because it changes which
    # accounts appear in a figure users have already seen.
    def period_return_unconvertible_account_ids(period)
      @period_return_unconvertible ||= {}
      @period_return_unconvertible[period.date_range] ||= begin
        # No `joins(:account)`: every column read here (`account_id`,
        # `currency`) is on `balances` itself, so the join added a scan and
        # nothing else.
        rows = Balance
          .where(account_id: investment_account_ids)
          .where("balances.date <= ?", period.date_range.end)
          .where.not(currency: family.currency)
          .distinct
          .pluck(:account_id, :currency)

        convertible = ExchangeRate
          .where(from_currency: rows.map(&:last).uniq, to_currency: family.currency)
          .distinct
          .pluck(:from_currency)
          .to_set

        rows.reject { |_, currency| convertible.include?(currency) }.map(&:first).uniq
      end
    end

    # One shape for all four classification groupings: read the column off the
    # security, fall back to UNCLASSIFIED, and place each account's positive
    # cash balance where that grouping says it belongs.
    #
    # `cash_bucket` is the argument that matters. Cash is not a holding -- it
    # sits on the account -- so every grouping has to say where it goes, and
    # the honest answer differs. A cash balance IS liquidity, and IS cash as a
    # sub-class. It has no sector and no region, so for those it falls to
    # UNCLASSIFIED rather than being invented into someone's slice.
    def allocation_by_classification(column, cash_bucket: nil, look_through: false)
      grouped = Hash.new(0)

      current_holdings.each do |holding|
        value = convert_to_family_currency(holding.amount, holding.currency)
        split = look_through ? look_through_split(holding.security, column, value, cash_bucket) : nil

        if split
          split.each { |bucket, portion| grouped[bucket] += portion }
        else
          grouped[classification_bucket(holding.security, column, cash_bucket)] += value
        end
      end

      investment_accounts.each do |account|
        cash = account.cash_balance.to_d
        next unless cash.positive?

        grouped[cash_bucket || UNCLASSIFIED] += convert_to_family_currency(cash, account.currency)
      end

      build_segments(grouped.map { |bucket, value| [ bucket, bucket, value ] })
    end

    # A fund's value spread across the classification of what it actually holds.
    # Returns nil -- not an empty hash -- for anything that is not a fund, so the
    # caller can tell "look through to nothing" from "not a fund", and an
    # ordinary holding is left entirely alone by the toggle.
    #
    # A constituent is stored as a bare ticker, so its classification comes from
    # a `Security` row when one exists. When it does not, the portion is carried
    # as UNCLASSIFIED rather than dropped: dropping it would shrink the portfolio
    # total by the weight of every constituent we happen not to hold, which for a
    # broad index fund is nearly all of it.
    def look_through_split(security, column, value, cash_bucket = nil)
      weights = constituent_weights_for(security)
      return nil if weights.empty?

      known = constituent_securities

      weights.each_with_object(Hash.new(0)) do |(ticker, weight), split|
        constituent = known[ticker.to_s.upcase]
        # `cash_bucket` is carried through: a constituent whose own Security row
        # is `kind: "cash"` belongs in liquidity/cash exactly as a directly held
        # cash security does. Passing nil filed it under UNCLASSIFIED, so the
        # same money answered differently depending on how it was held.
        bucket = constituent ? classification_bucket(constituent, column, cash_bucket) : UNCLASSIFIED
        split[bucket] += value * weight
      end
    end

    # ONE row set that every look-through level slices, rather than each level
    # deriving its own answer (#217). A fund contributes a row per constituent;
    # anything that is not a fund contributes one row for itself. Both carry the
    # SAME pair of buckets, so the asset-class level and the sub-class level are
    # two groupings of the same rows and cannot come to disagree -- which is
    # exactly how #201's contradiction arose, with parents from the constituents
    # and children from the fund's own columns.
    #
    # Costs no query of its own: `constituent_rows_by_security` and
    # `constituent_securities` are both memoised and both already paid for by
    # the parent segments, which is only true because #219 made the resolution
    # one query for the whole portfolio rather than one per fund.
    #
    # The NAME comes from the constituent row, never from the resolved
    # `Security`. `Security::Constituent` carries its own ticker and name, so a
    # constituent whose listing is ambiguous (#214) is still labelled correctly
    # even though its classification is unknown -- naming it from the resolved
    # row would print the wrong listing's name for precisely the case that
    # ambiguity rule exists to handle.
    def look_through_rows
      @look_through_rows ||= current_holdings.flat_map do |holding|
        value = convert_to_family_currency(holding.amount, holding.currency)
        weights = constituent_weights_for(holding.security)

        if weights.empty?
          [ {
            asset_class: classification_bucket(holding.security, :asset_class, "liquidity"),
            asset_sub_class: classification_bucket(holding.security, :asset_sub_class, "cash"),
            id: holding.security_id,
            name: holding.security.name.presence || holding.security.ticker,
            value: value
          } ]
        else
          names = constituent_names_for(holding.security)
          weights.map do |ticker, weight|
            key = ticker.to_s.upcase
            constituent = constituent_securities[key]
            {
              asset_class: constituent ? classification_bucket(constituent, :asset_class, "liquidity") : UNCLASSIFIED,
              asset_sub_class: constituent ? classification_bucket(constituent, :asset_sub_class, "cash") : UNCLASSIFIED,
              id: key,
              name: names[key].presence || key,
              value: value * weight
            }
          end
        end
      end
    end

    # Constituent labels by upcased ticker, from the rows themselves.
    def constituent_names_for(security)
      (constituent_rows_by_security[security.id] || []).each_with_object({}) do |row, map|
        map[row.ticker.to_s.upcase] ||= row.name
      end
    end

    # Constituent rows for every security in scope, fetched once. Asking each
    # security for `look_through_weights` runs a query per holding -- 42 against
    # 5 on 13 holdings -- and most holdings are not funds, so nearly all of them
    # were queries that returned nothing.
    def constituent_weights_for(security)
      rows = constituent_rows_by_security[security.id]
      return {} if rows.blank?

      total = rows.sum(&:weight)
      return {} if total.zero?

      rows.each_with_object({}) { |row, map| map[row.ticker] = row.weight / total }
    end

    # Extracted so the ticker resolver can read the same rows without triggering
    # a second load, and so "does this portfolio hold any fund at all" is one
    # query rather than one per asker.
    def constituent_rows_by_security
      @constituents_by_security ||= Security::Constituent
        .where(security_id: current_holdings.map(&:security_id).uniq)
        .where.not(weight: nil)
        .group_by(&:security_id)
    end

    # A constituent is stored as a bare ticker, and `securities` deliberately
    # allows one ticker on several exchanges -- `Security` scopes its uniqueness
    # to `exchange_operating_mic`. The previous `index_by` kept ONE arbitrary row
    # per ticker and discarded the rest, and since the query has no ORDER BY the
    # survivor was whichever Postgres returned last. That row then supplied the
    # asset class, sector and region the fund's slice was filed under, so the
    # same portfolio could classify the same money differently on two runs while
    # the total stayed right and nothing said so (#214).
    #
    # The rule, decided on that issue: prefer the listing the FAMILY HOLDS,
    # because a household's own positions are the best evidence available of
    # which listing a fund means. Where that does not decide it, resolve to
    # nothing and NAME it -- visible incompleteness over invisible wrongness.
    #
    # "Resolve to nothing" is about classification, not about the total. The
    # caller files an unresolved constituent under UNCLASSIFIED and still counts
    # its value, exactly as it already does for a ticker with no `Security` row.
    # Dropping it would shrink the portfolio by the weight of every colliding
    # ticker.
    #
    # Resolved for the WHOLE PORTFOLIO in one query rather than per fund (#219).
    # Per-fund resolution cost a query each, which `data_quality_issues` -- a
    # section with a deliberate query budget -- would have paid on every page
    # load once it started consulting this.
    def constituent_securities
      return @constituent_securities if defined?(@constituent_securities)

      tickers = all_constituent_tickers
      @constituent_securities = {}
      return @constituent_securities if tickers.empty?

      candidates = Security.where("upper(ticker) IN (?)", tickers).group_by { |s| s.ticker.to_s.upcase }
      tickers.each { |ticker| @constituent_securities[ticker] = resolve_constituent(ticker, candidates[ticker] || []) }
      @constituent_securities
    end

    # Every constituent ticker across every held security, from the rows
    # `constituent_weights_for` already loads in one query.
    def all_constituent_tickers
      constituent_rows_by_security.values.flatten.map { |row| row.ticker.to_s.upcase }.uniq
    end

    # One row resolves. Several resolve only if the family holds exactly one of
    # them; otherwise the ticker is recorded as ambiguous and resolves to nil.
    #
    # Holding SEVERAL of the candidates is still ambiguous: the household owning
    # both the London and the Sydney line is no evidence about which one a fund
    # reported, and picking either would be the same silent guess in a smaller
    # set.
    def resolve_constituent(ticker, rows)
      return nil if rows.empty?
      return rows.first if rows.one?

      held = rows.select { |row| held_security_ids.include?(row.id) }
      return held.first if held.one?

      ambiguous_constituent_tickers << ticker
      nil
    end

    def held_security_ids
      @held_security_ids ||= current_holdings.map(&:security_id).to_set
    end

    def ambiguous_constituent_tickers
      constituent_securities
      @ambiguous_constituent_tickers ||= Set.new
    end

    # Grouping by the household's own scheme rather than by a taxonomy everyone
    # shares. Scoped to `family.tags`, which is what keeps one family's scheme off
    # another's chart -- the security row itself is shared.
    #
    # Unlike a taxonomy, a security may carry SEVERAL tags, and that has to be
    # resolved rather than waved through. Counting the holding once per tag makes
    # the segments sum to more than the portfolio, and this section renders as a
    # donut: segments that overrun the total draw a chart that is simply wrong,
    # and `allocation_by` is covered by an invariant test asserting every grouping
    # adds up to `portfolio_value`.
    #
    # So a multi-tagged holding is SPLIT evenly across its tags. "Half in pension,
    # half in tech bet" is an answer a reader can act on; a donut summing to 140%
    # is not.
    #
    # Account cash is carried the same way the classification groupings carry it,
    # under UNCLASSIFIED -- cash is not tagged, and leaving it out would drop it
    # from this grouping alone.
    def allocation_by_tag
      family_tags = family.tags.index_by(&:id)
      grouped = Hash.new(0)
      names = { UNCLASSIFIED => UNCLASSIFIED }

      # One query for every security in scope rather than one per holding.
      # `holding.security.taggings` lazy-loads, so the obvious loop is an N+1 --
      # measured at 19 queries against 5 for `sector` on 13 holdings.
      tag_ids_by_security = Tagging
        .where(taggable_type: "Security", taggable_id: current_holdings.map(&:security_id).uniq)
        .where(tag_id: family_tags.keys)
        .pluck(:taggable_id, :tag_id)
        .group_by(&:first)
        .transform_values { |rows| rows.map(&:last) }

      current_holdings.each do |holding|
        value = convert_to_family_currency(holding.amount, holding.currency)
        ids = tag_ids_by_security.fetch(holding.security_id, [])

        if ids.empty?
          grouped[UNCLASSIFIED] += value
          next
        end

        # The last slice takes the remainder rather than another `share`.
        # BigDecimal division of a value that does not divide evenly leaves the
        # parts summing to slightly more than the whole -- 2150 over three tags
        # came back as 2150.000000000000000000000000000001 -- and an allocation
        # whose parts do not add back to the portfolio is wrong even when the
        # gap is 1e-27. The invariant tests could not see it: they compare
        # groupings with a 0.01 delta, which is exactly where a lost or gained
        # fraction hides. Raised by Codacy on #201.
        share = value / ids.length
        ids.each_with_index do |id, index|
          key = id.to_s
          portion = index == ids.length - 1 ? value - (share * (ids.length - 1)) : share
          grouped[key] += portion
          names[key] = family_tags[id].name
        end
      end

      investment_accounts.each do |account|
        cash = account.cash_balance.to_d
        next unless cash.positive?

        grouped[UNCLASSIFIED] += convert_to_family_currency(cash, account.currency)
      end

      build_segments(grouped.map { |key, value| [ key, names[key], value ] })
    end

    # Sub-classes inside one asset class. Cash is carried here too: it belongs
    # to `liquidity`/`cash`, so expanding Liquidity has to show it rather than
    # an empty list that contradicts the parent row's amount.
    def allocation_sub_classes_within(asset_class, look_through: false)
      grouped = Hash.new(0)

      if look_through
        look_through_rows.each do |row|
          next unless row[:asset_class] == asset_class

          grouped[row[:asset_sub_class]] += row[:value]
        end
      else
        holdings_classified_as(:asset_class, asset_class, "liquidity").each do |holding|
          bucket = classification_bucket(holding.security, :asset_sub_class, "cash")
          grouped[bucket] += convert_to_family_currency(holding.amount, holding.currency)
        end
      end

      if asset_class == "liquidity"
        investment_accounts.each do |account|
          cash = account.cash_balance.to_d
          grouped["cash"] += convert_to_family_currency(cash, account.currency) if cash.positive?
        end
      end

      build_segments(grouped.map { |bucket, value| [ bucket, bucket, value ] })
    end

    # The bottom of the ladder. Named by security so the row reads as a position
    # rather than as another bucket.
    #
    # Under look-through it is the CONSTITUENTS instead, which is the whole point
    # of #217: the toggle exists to answer "what am I actually exposed to", and
    # the classes above it never answer "to what". Several funds holding the same
    # ticker collapse into one row, because the exposure is one exposure however
    # many wrappers it arrives through -- which is the most useful thing this
    # level says.
    def allocation_holdings_within(column, bucket, cash_bucket = nil, look_through: false)
      if look_through
        grouped = Hash.new(0)
        names = {}
        look_through_rows.each do |row|
          next unless row[column] == bucket

          grouped[row[:id]] += row[:value]
          names[row[:id]] ||= row[:name]
        end
        return build_segments(grouped.map { |id, value| [ id, names[id], value ] })
      end

      rows = holdings_classified_as(column, bucket, cash_bucket).map do |holding|
        [ holding.security_id, holding.security.name.presence || holding.security.ticker,
          convert_to_family_currency(holding.amount, holding.currency) ]
      end
      build_segments(rows)
    end

    # One rule for which bucket a holding falls in, shared by the grouping, the
    # drill-down and the filter, so the three cannot disagree.
    #
    # A cash security is answered from `cash?` rather than from its columns. A
    # non-primary-currency cash position is a real holding -- `Security.cash_for`
    # creates one per currency -- and until the defaults slice populates the
    # taxonomy its `asset_class` is nil. Reading the column alone would file the
    # family's euros under Unclassified while the account's own euro cash
    # balance sat under Liquidity: two answers for the same money on one chart.
    def classification_bucket(security, column, cash_bucket)
      return cash_bucket if security.cash? && cash_bucket.present?

      security.public_send(column).presence || UNCLASSIFIED
    end

    def holdings_classified_as(column, bucket, cash_bucket = nil)
      current_holdings.select do |holding|
        classification_bucket(holding.security, column, cash_bucket) == bucket
      end
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
    def weight_denominator(rolled_up)
      holdings_total = rolled_up.sum { |_, value, _| value }
      [ portfolio_value, holdings_total ].max
    end

    # Groups current holdings by security and sums family-currency value.
    # Returns [[security, value, holdings], ...] sorted by value descending.
    # Callers that need return trends should call combined_holding_trend only
    # for rows they will render (e.g. after top_holdings applies its limit).
    #
    # Only holding rows with a positive value count, and a security left with
    # none is omitted rather than listed at weight 0 or at a negative weight
    # (methodology P27). Zero is a position with no price yet. Negative is
    # corrupt data: Holding validates qty, price and amount as non-negative,
    # but Holding::Materializer writes through upsert_all, which does not run
    # validations, so an over-sell can land one. Keeping it out is what makes
    # the weight denominator a real ceiling -- with a negative row in the sum,
    # holdings_total falls below the largest row and its weight goes over 100.
    #
    # The filter is per row, not on the netted total: current_holdings is
    # DISTINCT ON (account_id, security_id), so one security held in two
    # accounts yields two rows, and a negative row in one would otherwise net
    # against the good row in the other. The filtered rows are returned so
    # the trend excludes the bad row too.
    #
    # Memoized: top_holdings and allocation both start here, and the
    # grouping and FX conversion need only run once per instance.
    def holdings_rolled_up_by_security
      @holdings_rolled_up_by_security ||= holdings_with_avg_costs
        .group_by(&:security_id)
        .filter_map do |_security_id, holdings|
          positive_holdings = holdings.select do |holding|
            convert_to_family_currency(holding.amount, holding.currency).positive?
          end
          next if positive_holdings.empty?

          security = positive_holdings.first.security
          value = positive_holdings.sum { |h| convert_to_family_currency(h.amount, h.currency) }

          [ security, value, positive_holdings ]
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
        # totals; v3: fees, and contributions net of reported fees; v4: a
        # zero-amount Fee-labelled trade counts its fee column) so a deploy
        # never serves the previous shape from Redis.
        "investment_statement", "totals_query/v4", family.id, user&.id,
        account_ids_hash, date_range.begin, date_range.end, family.entries_cache_version
      ]) { Totals.new(family, account_ids: account_ids, date_range: date_range).call }
    end

    def monetizable_currency
      family.currency
    end
end
