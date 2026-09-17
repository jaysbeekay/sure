# The list of sections the portfolio hub renders, in the order the user last
# left them.
#
# Same shape as ReportsController#build_reports_sections -- a hash per section
# with `key`, an i18n `title` key, a `partial`, its `locals`, and the `visible`
# / `collapsible` flags -- so the Reports section chrome (drag to reorder,
# chevron to collapse) renders it unchanged. It lives here rather than in the
# controller because the ordering rule and the section list are domain
# decisions the controller only renders, and because a PORO can be unit-tested
# without a request.
#
# Every local a partial needs is passed in. Nothing here (and nothing in the
# partials) reads Date.current or Current.family: the controller captures one
# `as_of` and one statement per request and hands them down, so the sections
# that take a date all read the same one. That does not reach
# InvestmentStatement's snapshot FX, which converts at today's rate by its own
# contract (see PortfoliosController#show), so a render straddling midnight can
# still pick up the next day's rates there.
class Portfolio::SectionRegistry
  # The built-in section keys, in declaration order. The preferences
  # endpoint accepts only these, so a saved order or collapsed set cannot
  # carry arbitrary strings into the user's preferences.
  KEYS = %w[kpis performance index_chart comparison drivers value_chart realized_gains holdings accounts allocation data_quality].freeze

  attr_reader :statement, :period, :as_of, :user, :sort, :dir, :by, :extra_sections

  # `sort`, `dir` and `by` are the query-string state of the holdings table
  # and the allocation donut, passed through as given: the statement
  # whitelists them (InvestmentStatement::HOLDINGS_SORT_KEYS,
  # ALLOCATION_GROUPINGS) and falls back to its defaults for anything else.
  #
  # `extra_sections` are appended after the built-ins, in the order given. It
  # is the seam that keeps this list open: a later drop (or a test) can add a
  # section without editing the built-in list.
  def initialize(statement:, period:, as_of:, user:, sort: nil, dir: nil, by: nil, extra_sections: [])
    @statement = statement
    @period = period
    @as_of = as_of
    @user = user
    @sort = sort
    @dir = dir
    @by = by
    @extra_sections = extra_sections || []
  end

  def sections
    all = built_in_sections + extra_sections

    # Order by the user's saved order; anything the saved order doesn't
    # mention (a section added since they last dragged one) is appended in
    # declaration order, so a new section always appears rather than
    # disappearing until the next drag. Same rule as Reports.
    # `uniq` before the lookup: a saved order that repeats a key would
    # otherwise render that section once per occurrence. The endpoint
    # deduplicates what it writes, but an order stored before it did -- or
    # written by anything else -- still has to render once.
    ordered = Array(user&.section_order("portfolio")).uniq.filter_map do |key|
      all.find { |section| section[:key] == key }
    end

    # Matched by key, never by comparing whole section hashes: a section's
    # locals carry the statement and whatever it has memoised, and the order
    # must not depend on how those compare.
    placed = ordered.map { |section| section[:key] }
    ordered + all.reject { |section| placed.include?(section[:key]) }
  end

  private
    def built_in_sections
      [
        {
          key: "kpis",
          title: "portfolios.sections.kpis",
          partial: "portfolios/kpi_row",
          locals: shared_locals.merge(kpis: kpis),
          visible: true,
          collapsible: true
        },
        # Always visible, like kpis and value_chart. A period in which no
        # figure could be computed is a fact about the portfolio worth showing
        # -- the section says which figures are missing and why -- where a
        # vanishing section reads as "this page does not do returns".
        {
          key: "performance",
          title: "portfolios.sections.performance",
          partial: "portfolios/performance",
          locals: shared_locals.merge(performance: performance, returns: returns),
          visible: true,
          collapsible: true
        },
        # Hidden when the period cannot produce two points to join. Unlike the
        # performance cards, an empty chart says nothing a sentence could not
        # say better, and the cards above already state why a period has no
        # figures.
        {
          key: "index_chart",
          title: "portfolios.sections.index_chart",
          partial: "portfolios/index_chart",
          locals: shared_locals.merge(series: index_chart_series),
          visible: index_chart_series.present?,
          collapsible: true
        },
        # Hidden when the period moved nothing: a table of zeros reconciling to
        # zero is true and tells the reader nothing.
        # D7: the largest five accounts plus the portfolio as a whole. Capped
        # because each line costs one Portfolio::Performance; uncapped, the
        # page's query count would grow with the number of accounts a family
        # holds, and the hub's flatness guarantee would be gone.
        #
        # Hidden below two lines: comparing one account against the whole
        # portfolio it is the entirety of draws two identical lines.
        {
          key: "comparison",
          title: "portfolios.sections.comparison",
          partial: "portfolios/comparison",
          locals: shared_locals.merge(series: comparison_series),
          visible: comparison_series.size > 1,
          collapsible: true
        },
        {
          key: "drivers",
          title: "portfolios.sections.drivers",
          partial: "portfolios/drivers",
          locals: shared_locals.merge(drivers: drivers, contributions: driver_contributions,
                                      reconciles: driver_reconciles?),
          visible: drivers.present? && driver_contributions.any?,
          collapsible: true
        },
        {
          key: "value_chart",
          title: "portfolios.sections.value_chart",
          partial: "portfolios/value_chart",
          locals: shared_locals.merge(series: statement.value_series(period: period)),
          visible: true,
          collapsible: true
        },
        # Hidden when nothing was realised in the period: a P&L timeline with no
        # disposals in it is an empty chart, not a finding, and the section
        # chrome around it would read as one.
        {
          key: "realized_gains",
          title: "portfolios.sections.realized_gains",
          partial: "portfolios/realized_gains",
          locals: shared_locals.merge(realized: realized_gains, bars: realized_gains_bars),
          visible: realized_gains.any?,
          collapsible: true
        },
        {
          key: "holdings",
          title: "portfolios.sections.holdings",
          partial: "portfolios/holdings",
          locals: shared_locals.merge(rows: holdings_rows, sort: sort, dir: dir, by: by),
          visible: holdings_rows.any?,
          collapsible: true
        },
        {
          key: "accounts",
          title: "portfolios.sections.accounts",
          partial: "portfolios/accounts",
          locals: shared_locals,
          visible: statement.investment_accounts.any?,
          collapsible: true
        },
        {
          key: "allocation",
          title: "portfolios.sections.allocation",
          partial: "portfolios/allocation",
          locals: shared_locals.merge(segments: allocation_segments, by: by, sort: sort, dir: dir),
          visible: allocation_segments.any?,
          collapsible: true
        },
        # Hidden when there is nothing to fix: an empty "data quality" section
        # would read as a problem in itself.
        {
          key: "data_quality",
          title: "portfolios.sections.data_quality",
          partial: "portfolios/data_quality",
          locals: shared_locals.merge(issues: data_quality_issues, writable_account_ids: writable_account_ids),
          visible: data_quality_issues.any?,
          collapsible: true
        }
      ]
    end

    # The six KPI figures, read from the statement here so the partial only
    # formats them.
    def kpis
      @kpis ||= {
        value: statement.portfolio_value_money,
        day_change: statement.day_change,
        unrealized: statement.unrealized_gains_trend,
        period_return: statement.period_return_trend(period: period),
        net_contributions: statement.net_contributions(period: period),
        income: statement.totals(period: period).total_income
      }
    end

    # One Portfolio::Performance for the request, so the six figures below and
    # the disclosure flags all come from a single computation over a single
    # period rather than from six that could each re-derive it.
    def performance
      @performance ||= statement.performance(period: period)
    end

    # The six return figures, read here so the partial only formats. Each may
    # be nil by contract -- R13 (missing rate), R15 (fewer than two balance
    # days), R16 (no money-weighted return for a valuation-only scope) -- and
    # nil is passed through rather than defaulted, because a zero return and no
    # return are different statements.
    def returns
      @returns ||= {
        twr: performance.time_weighted_return,
        annualized_twr: performance.annualized_time_weighted_return,
        mwr: performance.money_weighted_return,
        annualized_mwr: performance.annualized_money_weighted_return,
        volatility: performance.volatility,
        max_drawdown: performance.max_drawdown
      }
    end

    # The flow-adjusted index as a Series the time-series chart can draw.
    #
    # Built here rather than in the partial for the same reason the realised
    # P&L bars are: the view formats, it does not assemble. Built here rather
    # than on Portfolio::Performance because a Series is a presentation shape,
    # and that class stays free of one.
    #
    # `index_series` is [[date, level], ...] rebased on 100, so the values are
    # plain BigDecimals rather than Money. Series passes a non-Money value
    # through untouched (`display_amount`), and the chart's tooltip then reads
    # a level and a percentage change -- which is what an index is, and why
    # this is not the value chart with different numbers in it.
    #
    # from_raw_values demands two values, and a period with one day or none has
    # no line to draw; nil here is what hides the section.
    def index_chart_series
      return @index_chart_series if defined?(@index_chart_series)

      # Size checked before mapping: a period with one point or none has no line
      # to draw, and building the hashes only to discard them is allocation for
      # nothing on a page that renders this on every request.
      levels = performance.index_series
      @index_chart_series =
        if levels.size >= 2
          # Rounded to two places HERE, because nothing downstream will do it.
          # A chained level is a BigDecimal division result --
          # 112.30000000000000000000000000000311 for an ordinary two-day series
          # -- and Series#display_amount passes a non-Money value through
          # untouched, Trend#as_json emits it raw, and the chart's
          # _extractFormattedValue returns it verbatim. The hover would read
          # every one of those digits. The percentage half is already fine:
          # Trend#percent_formatted rounds it.
          Series.from_raw_values(
            levels.map { |date, level| { date: date, value: level.round(2) } }
          )
        end
    end

    # A Hash, not a Portfolio::Drivers. Portfolio::Performance caches its
    # metrics, so it stores `drivers.to_h` rather than the object -- which also
    # means `reconciles?` is not available here and has to be re-derived from
    # `unexplained` (see driver_reconciles? below).
    # D7's cap. Five is a product decision, not a technical limit, but the
    # technical consequence is the one that matters here: the page costs one
    # Portfolio::Performance per line, so the cap is what keeps its query count
    # independent of how many accounts a family holds.
    COMPARISON_LIMIT = 5

    # The flow-adjusted index for each of the largest five accounts, plus the
    # whole portfolio.
    #
    # The INDEX, not the value: accounts that received deposits at different
    # times are not comparable by value, and removing that difference is the
    # whole reason a time-weighted return exists. Two accounts that returned
    # the same amount plot as the same line here even if one of them is ten
    # times the size of the other.
    #
    # Each account's own Performance is built with its own id as the scope
    # (the default), NOT the wider portfolio. That is deliberate and is the
    # difference between two defensible readings: money moved from account A to
    # account B is internal to the portfolio, and a CONTRIBUTION to B. A line
    # labelled "B" has to answer "what did B return", so B's scope is B.
    def comparison_series
      @comparison_series ||= begin
        lines = comparison_accounts.filter_map do |account|
          # active_until_dates matters as much here as it does for the
          # portfolio line. It carries each account's historical cut-off, and
          # InvestmentStatement#performance passes it for the aggregate -- so
          # without it a disabled account's line would run past the date the
          # baseline stops at, and the two would be drawn over different spans
          # while inviting comparison.
          points = Portfolio::Performance.new(
            family: statement.family, account_ids: [ account.id ], period: period, user: user,
            active_until_dates: statement.historical_scope.active_until_dates.slice(account.id)
          ).index_series

          next if points.size < 2

          { label: account.name, values: points.map { |date, level| { date: date, value: level } } }
        end

        # No baseline, no comparison. When the portfolio's own series is
        # withheld -- R13's missing rate, or R15's too-short history -- the
        # account lines have nothing to be read against, and a chart of
        # individual accounts presented as a comparison would invite exactly
        # the reading the withholding exists to prevent.
        whole = performance.index_series

        if whole.size < 2
          []
        else
          lines.unshift(label: I18n.t("portfolios.comparison.whole_portfolio"),
                        values: whole.map { |date, level| { date: date, value: level } })
          lines
        end
      end
    end

    # The largest five by closing value on the period's END date, tie-broken by
    # name so the set is stable between renders rather than left to whatever
    # order the database returns.
    #
    # One query for the balances and one for the rates, so the selection does
    # not grow with the account count either -- the cap would be pointless if
    # choosing what to cap cost a query per account.
    #
    # An account whose currency has no rate is ranked last rather than
    # converted at parity (R13). It is still listed if it reaches the cap; what
    # it must not do is outrank a real figure on the strength of a fabricated
    # one.
    def comparison_accounts
      @comparison_accounts ||= begin
        accounts = statement.historical_scope.accounts.to_a
        values = closing_values_for(accounts)
        # Rate availability sorts FIRST, then value. Ranking a rateless account
        # as zero is not enough: an account that genuinely closed at zero or
        # below would then be outranked by one whose value is merely unknown,
        # which is the parity mistake in a different shape -- a missing figure
        # winning a comparison it was never measured for.
        accounts.sort_by { |account|
          value = values[account.id]
          [ value.nil? ? 1 : 0, -(value || BigDecimal(0)), account.name.to_s ]
        }.first(COMPARISON_LIMIT)
      end
    end

    def closing_values_for(accounts)
      return {} if accounts.empty?

      end_date = period.date_range.end
      rates = rates_on_or_before(accounts.map(&:currency).uniq, end_date)

      # Restricted to the row in the ACCOUNT's own currency. `balances` can
      # carry rows in another currency for the same account and day -- a legacy
      # or orphaned row from a currency change -- and DISTINCT ON without this
      # would rank the account from whichever of them sorted first.
      Balance.joins(:account)
             .where(account_id: accounts.map(&:id))
             .where(date: ..end_date)
             .where("balances.currency = accounts.currency")
             .select("DISTINCT ON (balances.account_id) balances.account_id, balances.end_balance, balances.flows_factor, balances.currency")
             .order("balances.account_id", "balances.date DESC")
             .each_with_object({}) do |balance, acc|
        rate = balance.currency == statement.family.currency ? BigDecimal(1) : rates[balance.currency]
        next if rate.nil?

        acc[balance.account_id] = balance.end_balance * balance.flows_factor * rate
      end
    end

    def rates_on_or_before(currencies, date)
      foreign = currencies.reject { |currency| currency == statement.family.currency }
      return {} if foreign.empty?

      # R13's lookup, both sides: the most recent rate on or before the date,
      # and failing that the earliest one after it. A one-sided lookup would
      # report a currency whose first stored rate falls after the period end as
      # having no rate at all, and push a perfectly measurable account behind
      # the cap.
      on_or_before = ExchangeRate.where(from_currency: foreign, to_currency: statement.family.currency)
                                 .where(date: ..date)
                                 .order(:from_currency, date: :desc)
                                 .select("DISTINCT ON (from_currency) from_currency, rate")
                                 .each_with_object({}) { |row, acc| acc[row.from_currency] = row.rate }

      missing = foreign - on_or_before.keys
      return on_or_before if missing.empty?

      after = ExchangeRate.where(from_currency: missing, to_currency: statement.family.currency)
                          .where("date > ?", date)
                          .order(:from_currency, :date)
                          .select("DISTINCT ON (from_currency) from_currency, rate")
                          .each_with_object({}) { |row, acc| acc[row.from_currency] = row.rate }

      on_or_before.merge(after)
    end

    def drivers
      @drivers ||= performance.drivers || {}
    end

    # R12 held, re-derived from the cached hash because Portfolio::Performance
    # stores `drivers.to_h` and the object's own `reconciles?` does not survive
    # that. Re-derived at the SAME tolerance the contract defines -- a cent, per
    # Portfolio::Drivers#reconciles?(tolerance: BigDecimal("0.01")) -- and not
    # at exact zero.
    #
    # Read from Portfolio::Drivers rather than written out again. This was a
    # second literal, and the two had already drifted once -- exact zero here,
    # a cent there -- so the section could call a period unreconciled while
    # `Drivers#reconciles?` called it reconciled. See that constant for what
    # the cent is for and where it does not hold.
    def driver_reconciles?
      drivers[:unexplained].to_d.abs <= Portfolio::Drivers::RECONCILE_TOLERANCE
    end

    # The decomposition as SIGNED contributions, in the order they are added.
    #
    # Signing happens here rather than in the partial because the sign is a
    # contract rule, not a formatting choice. R12's identity is
    #
    #   external_net + composition + income - fees + market + revaluations
    #     + fx_effect == value_close - value_open
    #
    # and `fees` is reported by Portfolio::Drivers as a POSITIVE magnitude that
    # REDUCES the change (R7). A table that rendered each component as given
    # would show fees adding to the portfolio and would not sum to the change
    # it sits under. Negating it here keeps the one place that knows the rule
    # next to the comment that states it.
    #
    # `unexplained` is included only when it is not zero. It is expected to be
    # zero and is measured rather than defined so (see Portfolio::Drivers), so
    # a non-zero value is a real finding and hiding it would be the dishonest
    # choice; a zero row would just be noise.
    #
    # Zero components are dropped: a period with no fees does not need a fees
    # row to say so.
    def driver_contributions
      @driver_contributions ||= begin
        signed = [
          [ :external_net, drivers[:external_net] ],
          [ :composition, drivers[:composition] ],
          [ :income, drivers[:income] ],
          [ :fees, drivers[:fees] ? -drivers[:fees] : nil ],
          [ :market, drivers[:market] ],
          [ :revaluations, drivers[:revaluations] ],
          [ :fx_effect, drivers[:fx_effect] ],
          [ :unexplained, drivers[:unexplained] ]
        ]

        # Dropped when it rounds away as well as when it is exactly zero: an
        # "Unexplained $0.00" row states a gap the figure itself denies, and
        # sub-cent residue is normal in a multi-currency scope. "Rounds away"
        # is true at two decimal places; see Portfolio::Drivers::RECONCILE_TOLERANCE
        # for the zero-decimal currencies where it is not.
        signed.reject { |key, amount|
          next true if amount.nil? || amount.zero?

          key == :unexplained && amount.abs <= Portfolio::Drivers::RECONCILE_TOLERANCE
        }
      end
    end

    def holdings_rows
      @holdings_rows ||= statement.holdings_table_rows(sort: sort, dir: dir)
    end

    def realized_gains
      @realized_gains ||= statement.realized_gains(period: period)
    end

    # The bar payload, built here rather than in the partial so the view only
    # formats, and rather than on Portfolio::RealizedGains so that model stays
    # free of presentation. Same shape PagesController#build_money_flow_data
    # passes, including the short-label fallback for locales where "%b %Y" is
    # not short.
    #
    # `income` and `expense` are bar_chart_controller's wire format, not a
    # claim about what these figures are: the two series are positional, and
    # the labels the reader actually sees are passed separately as "Gains" and
    # "Losses". An earlier revision renamed the keys by generalising that
    # controller; the generalisation is not worth the blast radius on a widget
    # the dashboard also renders, so the payload speaks its format instead.
    #
    # Losses are already a positive magnitude on the bucket, which is what the
    # chart's scale expects; `net` carries the sign for the figures beside it.
    # `short_label` is the axis tick, and "%b" drops the year. Over a range
    # that spans more than one calendar year that prints two identical "Mar"
    # ticks for different months, so the year is carried once the buckets
    # cover more than one. Inside a single year it stays bare, which is what
    # fits the axis.
    def realized_gains_bars
      buckets = realized_gains.buckets
      short_format = buckets.map { |bucket| bucket.month.year }.uniq.size > 1 ? "%b %y" : "%b"

      @realized_gains_bars ||= buckets.map do |bucket|
        {
          date: bucket.month,
          label: I18n.l(bucket.month, format: :short_month_year),
          short_label: I18n.l(bucket.month, format: short_format),
          income: bucket.gains.to_f.round(2),
          expense: bucket.losses.to_f.round(2)
        }
      end
    end

    def allocation_segments
      @allocation_segments ||= statement.allocation_by(by)
    end

    def data_quality_issues
      @data_quality_issues ||= statement.data_quality_issues(as_of: as_of)
    end

    # The accounts the user may write to, for the data-quality rows that
    # offer the cost-basis drawer: one query here rather than a permission
    # lookup per row, and none when there is nothing to list.
    def writable_account_ids
      @writable_account_ids ||= if user && data_quality_issues.any?
        statement.family.accounts.writable_by(user).pluck(:id).to_set
      else
        Set.new
      end
    end

    def shared_locals
      { statement: statement, period: period, as_of: as_of }
    end
end
