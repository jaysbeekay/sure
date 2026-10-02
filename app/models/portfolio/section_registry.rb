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
  KEYS = %w[kpis performance index_chart comparison drivers value_chart realized_gains income holdings accounts allocation data_quality retirement].freeze

  attr_reader :statement, :period, :as_of, :user, :sort, :dir, :by, :look_through, :extra_sections

  # `sort`, `dir` and `by` are the query-string state of the holdings table
  # and the allocation donut, passed through as given: the statement
  # whitelists them (InvestmentStatement::HOLDINGS_SORT_KEYS,
  # ALLOCATION_GROUPINGS) and falls back to its defaults for anything else.
  #
  # `extra_sections` are appended after the built-ins, in the order given. It
  # is the seam that keeps this list open: a later drop (or a test) can add a
  # section without editing the built-in list.
  def initialize(statement:, period:, as_of:, user:, sort: nil, dir: nil, by: nil, look_through: false, extra_sections: [])
    @statement = statement
    @period = period
    @as_of = as_of
    @user = user
    @sort = sort
    @dir = dir
    @by = by
    @look_through = look_through
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
        # D7: the largest five accounts plus the portfolio as a whole. Capped
        # because each line costs one Portfolio::Performance; uncapped, the
        # page's query count would grow with the number of accounts a family
        # holds, and the hub's flatness guarantee would be gone.
        #
        # Hidden below three lines, and three rather than two because the first
        # is the baseline: a family with one account is compared against a
        # portfolio it is the entirety of, and the two lines are the same
        # series drawn twice. `> 1` read as "more than one line" and let that
        # case through.
        {
          key: "comparison",
          title: "portfolios.sections.comparison",
          partial: "portfolios/comparison",
          locals: shared_locals.merge(series: comparison_series),
          visible: comparison_series.size > 2,
          collapsible: true
        },
        # Hidden when the period moved nothing: a table of zeros reconciling to
        # zero is true and tells the reader nothing.
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
        # Always shown, and it says so when nothing was realised, rather than
        # disappearing. An earlier revision hid it on an empty period, reasoning
        # that a timeline with no disposals is an empty chart rather than a
        # finding. That holds for the chart and not for the section: a
        # buy-and-hold portfolio realises nothing in most periods, so the
        # section was absent for those users always, and absence reads as "this
        # page does not do that" rather than "you disposed of nothing". The
        # value chart answers the same question the same way (`no_data`), and
        # the partial keeps the figure and the chart out of an empty period.
        {
          key: "realized_gains",
          title: "portfolios.sections.realized_gains",
          partial: "portfolios/realized_gains",
          locals: shared_locals.merge(realized: realized_gains, bars: realized_gains_bars),
          visible: true,
          collapsible: true
        },
        # Always shown, for the reason realized_gains is: a portfolio that paid
        # nothing in the period is a fact, and a vanishing section reads as
        # "this page does not do income". `income` is a built-in key rather than
        # an `extra_sections` entry because a user has to be able to reorder and
        # collapse it -- the preferences endpoint accepts only KEYS.
        {
          key: "income",
          title: "portfolios.sections.income",
          partial: "portfolios/income",
          locals: shared_locals.merge(income: income, trailing: trailing_income, bars: income_bars,
                                      securities: income_by_security, yields: income_yields,
                                      rate_missing: income_rate_missing?),
          visible: true,
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
          locals: shared_locals.merge(segments: allocation_segments, by: by, sort: sort, dir: dir,
            look_through: look_through, look_through_available: look_through_available?),
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
        },
        # The FIRE card (#127, 8.1), for the viewer's own plan. Its figures are
        # built from the accounts this user counts in their finances -- the
        # same scope the statement uses -- at the registry's one `as_of`.
        # Hidden without a user, since a plan belongs to one.
        {
          key: "retirement",
          title: "portfolios.sections.retirement",
          partial: "portfolios/retirement",
          locals: shared_locals.merge(retirement: retirement),
          visible: user.present?,
          collapsible: true
        }
      ]
    end

    def retirement
      return nil if user.nil?

      @retirement ||= begin
        plan = RetirementPlan.for(user)
        { projection: plan.projection(as_of: as_of), unconverted_count: plan.unconverted_account_count(as_of: as_of) }
      end
    end

    # The six KPI figures, read from the statement here so the partial only
    # formats them.
    def kpis
      @kpis ||= {
        value: statement.portfolio_value_money,
        day_change: statement.day_change,
        unrealized: statement.unrealized_gains_trend,
        period_return: statement.period_return_trend(period: period),
        period_return_unconvertible: statement.period_return_unconvertible_count(period: period),
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
    # D7's cap. Five is a product decision; see the `comparison` entry above for
    # what it buys.
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

          { label: account.name, values: points.map { |date, level| { date: date, value: level.round(2) } } }
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
          # Rounded for the same reason index_chart_series rounds, and it matters
          # more here: a chained level is a BigDecimal division result carrying
          # ~35 digits, nothing downstream trims it, and up to six lines of them
          # are serialised into a data attribute on every render.
          lines.unshift(label: I18n.t("portfolios.comparison.whole_portfolio"),
                        values: whole.map { |date, level| { date: date, value: level.round(2) } })
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
        # Only accounts still contributing value at the period's end.
        # historical_scope includes disabled accounts by design -- their history
        # belongs in the aggregate -- but a closed broker with a large final
        # balance would rank into the top five, then lose its line to the
        # two-point guard below, and the slot would be spent on nothing while a
        # live account went undrawn.
        cutoffs = statement.historical_scope.active_until_dates
        period_end = period.date_range.end
        accounts = statement.historical_scope.accounts.reject { |account|
          cutoff = cutoffs[account.id]
          cutoff.present? && cutoff < period_end
        }
        values = closing_values_for(accounts)
        # Rate availability sorts FIRST, then value. Ranking a rateless account
        # as zero is not enough: an account that genuinely closed at zero or
        # below would then be outranked by one whose value is merely unknown,
        # which is the parity mistake in a different shape -- a missing figure
        # winning a comparison it was never measured for.
        # The id is the last resort, and it is what makes this a TOTAL order.
        # Without it two accounts can tie on every key -- which is not an edge
        # case: an account with no balance history has no closing value at all,
        # so the first two keys collapse to `[1, 0]` for every such account and
        # the name is all that is left. Two accounts can share a name.
        #
        # A tie here is decided by the order `accounts` arrived in, and that
        # comes from a query with no ORDER BY, so it is not stable between
        # requests. The page could plot one set of five and then a different set
        # on refresh, with nothing having changed. #240 is the same defect seen
        # from CI: a query-count assertion that moved by one because a different
        # account took the fifth slot.
        accounts.sort_by { |account|
          value = values[account.id]
          [ value.nil? ? 1 : 0, -(value || BigDecimal(0)), account.name.to_s, account.id ]
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

    # Portfolio::Performance#income for the selected period: a Hash, as
    # `drivers` is, and for the same reason (the metrics are cached).
    def income
      @income ||= performance.income
    end

    # The twelve months ending at `as_of`, whatever period the page is set to.
    # A yearly figure that moved with the picker would read as a different
    # number on every view; this one only moves with the date.
    #
    # Built from the registry's one `as_of` and never from Date.current, so it
    # cannot disagree with the sections beside it about what "now" is. Starts
    # the day after the same date a year earlier, so the window is a full year
    # and not a year and a day.
    def trailing_income
      @trailing_income ||= trailing_performance.income
    end

    def trailing_performance
      @trailing_performance ||= statement.performance(
        period: Period.custom(start_date: as_of.prev_year + 1.day, end_date: as_of)
      )
    end

    # The selected period's income by security. `total` is the figure the bars
    # and the drivers table report, so the table and its unattributed row add up
    # to it by construction (see Portfolio::IncomeBySecurity).
    def income_by_security
      @income_by_security ||= Portfolio::IncomeBySecurity.new(amounts: income[:by_security], total: income[:total])
    end

    # Yield-on-cost for each security in the table: the trailing twelve months'
    # income over the cost basis, { "security-uuid" => fraction or nil }. Every
    # row has a key, so the partial can tell "no figure" from "not asked for".
    #
    # The numerator is the TRAILING income, not the row's period amount. The
    # row answers "what did it pay in the period you picked" and a yield over
    # that would move with the picker; a yield is a yearly figure.
    #
    # LIMITATION, by the issue's own definition ("trailing income / cost basis"):
    # this divides a year of income by TODAY's cost basis. A position that was
    # partly sold during the year overstates the yield (income from shares no
    # longer in the denominator), and one bought recently understates it (a year
    # of denominator, a few months of income). It is a yield on what is held now,
    # not a time-weighted figure.
    #
    # nil, never zero, when it cannot be stated honestly:
    # - the security is not held, so there is no cost basis to divide by;
    # - a position's cost basis is unknown (`missing_cost_basis`), because the
    #   income covers the whole position and the basis only part of it;
    # - a rate is missing in either income window (R13), as every ratio on this
    #   page is withheld;
    # - a position behind the row is in a currency with no rate, so its cost
    #   basis was converted at parity (see #unrated_currencies).
    def income_yields
      @income_yields ||= begin
        trailing = Portfolio::IncomeBySecurity.new(amounts: trailing_income[:by_security], total: trailing_income[:total])
        withheld = income_rate_missing?
        held = holdings_rows.index_by { |row| row.security.id.to_s }

        unrated = unrated_currencies(held.values_at(*income_by_security.rows.map { |row| row.security.id.to_s }).compact)

        income_by_security.rows.to_h do |row|
          id = row.security.id.to_s
          [ id, withheld ? nil : yield_on_cost(held[id], trailing.amount_for(id), unrated) ]
        end
      end
    end

    # The currencies, among the positions behind these rows, that have no rate to
    # the family currency on record. The statement values a holding with
    # `rates[currency] || 1`, and ExchangeRate.rates_for ends the same way, so
    # neither can say "no rate" -- a EUR cost basis with none is converted at
    # parity and looks like any other. Read directly, as Portfolio::RealizedGains
    # does, and by the same R13 lookup the account comparison ranks with.
    def unrated_currencies(holding_rows)
      foreign = holding_rows.flat_map { |row| row.positions.map(&:currency) }.uniq - [ statement.family.currency ]
      return [] if foreign.empty?

      foreign - rates_on_or_before(foreign, as_of).keys
    end

    def yield_on_cost(holding_row, trailing_amount, unrated)
      return nil if holding_row.nil? || holding_row.missing_cost_basis
      # A cost basis converted at parity is not a cost basis. Only the positions
      # behind THIS row matter: a rateless currency elsewhere does not touch it.
      return nil if holding_row.positions.any? { |position| unrated.include?(position.currency) }

      cost = holding_row.unrealized&.previous&.amount
      return nil unless cost&.positive?

      trailing_amount / cost
    end

    # Whether a currency with no rate left something out of the income figures,
    # in either window, since the section prints both.
    #
    # The totals, fees and bars are MONEY and are reported whatever happens, as
    # Portfolio::Drivers' are; only the ratios are withheld (R13). But an entry
    # in a currency with no rate falls out of their SQL sum, so they are partial
    # without saying so. The section says so where the figures are, the way
    # Realised P&L names the disposals it left out, rather than leaving a total
    # that reads as complete. Both predicates are already computed for the
    # sections above, so this costs no query.
    def income_rate_missing?
      performance.rate_missing? || trailing_performance.rate_missing?
    end

    # The bar payload, in the shape and for the reasons realized_gains_bars
    # gives. The chart draws positive heights only, so a month that netted
    # NEGATIVE (a reversal larger than that month's payments) goes on the second
    # series as a magnitude rather than being dropped: income less reversals is
    # then the total the drivers table reports. For an ordinary month the second
    # series is zero.
    def income_bars
      @income_bars ||= begin
        buckets = income[:buckets]
        short_format = buckets.map { |bucket| bucket[:month].year }.uniq.size > 1 ? "%b %y" : "%b"

        buckets.map do |bucket|
          {
            date: bucket[:month],
            label: I18n.l(bucket[:month], format: :short_month_year),
            short_label: I18n.l(bucket[:month], format: short_format),
            income: [ bucket[:amount], 0 ].max.to_f.round(2),
            expense: [ -bucket[:amount], 0 ].max.to_f.round(2)
          }
        end
      end
    end

    # The toggle is only offered when the portfolio actually holds a fund we have
    # constituents for. Shown unconditionally it would be a control that visibly
    # does nothing for most people, and the look-through axes do not apply to
    # account, currency, kind, tag or security anyway.
    def look_through_available?
      return false unless by.to_s.in?(%w[asset_class asset_sub_class sector region])

      statement.holds_any_fund_constituents?
    end

    def allocation_segments
      @allocation_segments ||= statement.allocation_by(by, look_through: look_through)
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
