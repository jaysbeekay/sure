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
# `as_of` and one statement per request and hands them down, so a render that
# straddles midnight cannot show two different todays.
class Portfolio::SectionRegistry
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
    ordered = Array(user&.section_order("portfolio")).filter_map do |key|
      all.find { |section| section[:key] == key }
    end

    all.each { |section| ordered << section unless ordered.include?(section) }

    ordered
  end

  private
    def built_in_sections
      [
        {
          key: "kpis",
          title: "portfolios.sections.kpis",
          partial: "portfolios/kpi_row",
          locals: shared_locals,
          visible: true,
          collapsible: true
        },
        {
          key: "value_chart",
          title: "portfolios.sections.value_chart",
          partial: "portfolios/value_chart",
          locals: shared_locals,
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
          locals: shared_locals.merge(issues: data_quality_issues),
          visible: data_quality_issues.any?,
          collapsible: true
        }
      ]
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

    def shared_locals
      { statement: statement, period: period, as_of: as_of }
    end
end
