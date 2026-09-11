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
  KEYS = %w[kpis value_chart holdings accounts allocation data_quality].freeze

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
        {
          key: "value_chart",
          title: "portfolios.sections.value_chart",
          partial: "portfolios/value_chart",
          locals: shared_locals.merge(series: statement.value_series(period: period)),
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

    def holdings_rows
      @holdings_rows ||= statement.holdings_table_rows(sort: sort, dir: dir)
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
