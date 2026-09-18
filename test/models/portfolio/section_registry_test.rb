require "test_helper"

class Portfolio::SectionRegistryTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @family = @user.family
    @period = Period.last_30_days
    @as_of = Date.current
    @statement = InvestmentStatement.new(@family, user: @user)
  end

  test "registers the built-in sections with their partials and locals" do
    sections = registry.sections

    assert_equal %w[kpis performance value_chart realized_gains holdings accounts allocation data_quality], sections.map { |s| s[:key] }
    assert_equal %w[portfolios/kpi_row portfolios/performance portfolios/value_chart], sections.first(3).map { |s| s[:partial] }
    assert sections.all? { |s| s[:collapsible] }

    # Every partial gets its locals passed in: none of them reaches for
    # Date.current or Current.family on its own.
    sections.each do |section|
      assert_equal({ statement: @statement, period: @period, as_of: @as_of }, section[:locals].slice(:statement, :period, :as_of),
        "#{section[:key]} must receive the shared locals rather than reading them itself")
    end
  end

  # The six return figures come from ONE Portfolio::Performance for the request.
  # Six independently-derived figures could each re-read the period, which is
  # the class of defect the "one as_of, passed down" rule on this class exists
  # to prevent.
  test "the performance section reads every figure from one computation" do
    perf = Portfolio::Performance.new(family: @family, account_ids: [], period: @period)
    @statement.expects(:performance).with(period: @period).returns(perf).once

    section = registry.sections.find { |s| s[:key] == "performance" }

    assert_equal "portfolios/performance", section[:partial]
    assert_same perf, section[:locals][:performance]
    assert_equal %i[twr annualized_twr mwr annualized_mwr volatility max_drawdown].sort,
                 section[:locals][:returns].keys.sort
  end

  # nil is a contract outcome, not a gap: R13 suppresses a figure whose rate is
  # missing, R15 an account with fewer than two balance days, and R16 withholds
  # the money-weighted return from a valuation-only scope. Passing nil through
  # rather than defaulting is what lets the card say "no data" instead of
  # printing a zero return that nobody earned.
  test "the performance section passes a withheld figure through as nil" do
    perf = Portfolio::Performance.new(family: @family, account_ids: [], period: @period)
    perf.stubs(:time_weighted_return).returns(BigDecimal("0.21"))
    perf.stubs(:money_weighted_return).returns(nil)
    @statement.stubs(:performance).returns(perf)

    returns = registry.sections.find { |s| s[:key] == "performance" }[:locals][:returns]

    assert_equal BigDecimal("0.21"), returns[:twr]
    assert_nil returns[:mwr], "a withheld figure must not be defaulted to zero"
  end

  test "sections are visible only when the family has data for them" do
    visible = registry.sections.select { |s| s[:visible] }.map { |s| s[:key] }
    assert_includes visible, "holdings"
    assert_includes visible, "accounts"
    assert_includes visible, "allocation"

    # A family with no investment accounts has nothing to list beyond the
    # sections that speak for themselves when empty: the KPI row, the value
    # chart and the realised-P&L timeline, each of which says so rather than
    # disappearing. (The controller shows the whole-page empty state anyway.)
    empty_statement = InvestmentStatement.new(families(:empty), user: nil)
    empty = Portfolio::SectionRegistry.new(statement: empty_statement, period: @period, as_of: @as_of, user: @user).sections
    # `performance` joins kpis, value_chart and realized_gains as always-on: a
    # period with no computable figure is a fact worth stating, where a
    # vanishing section reads as "this page does not do returns". The same
    # argument #171 made for realised P&L, which is why both are here.
    assert_equal %w[kpis performance value_chart realized_gains], empty.select { |s| s[:visible] }.map { |s| s[:key] }
  end

  test "passes the sort, direction and grouping through to the holdings and allocation locals" do
    # Ticker order and name order disagree for this one: it sorts last by
    # ticker and first by name, so a name sort that secretly ordered by
    # ticker would put it in the wrong place.
    zebra = Security.create!(ticker: "ZZZA", name: "Aardvark Holdings")
    Holding.create!(
      account: accounts(:investment), security: zebra, date: Date.current,
      qty: 1, price: 10, amount: 10, currency: "USD", cost_basis: 8, cost_basis_locked: true
    )

    sections = Portfolio::SectionRegistry.new(
      statement: @statement, period: @period, as_of: @as_of, user: @user, sort: "name", dir: "asc", by: "kind"
    ).sections.index_by { |s| s[:key] }

    assert_equal "name", sections["holdings"][:locals][:sort]
    assert_equal "asc", sections["holdings"][:locals][:dir]
    assert_equal "kind", sections["allocation"][:locals][:by]
    # Ticker order and name order deliberately disagree, so an assertion that
    # only compared a sorted list against itself would pass either way.
    rows = sections["holdings"][:locals][:rows]
    names = rows.map { |row| row.name.downcase }
    assert_equal names.sort, names, "sort: \"name\" must order by security name, not ticker"
    assert_equal "ZZZA", rows.first.ticker, "the name sort must put Aardvark first despite its ticker"
    assert sections["data_quality"][:locals].key?(:issues)
    assert_equal %i[value day_change unrealized period_return net_contributions income], sections["kpis"][:locals][:kpis].keys
    assert_kind_of Series, sections["value_chart"][:locals][:series]
  end

  test "orders sections by the user's saved order, appending anything it omits" do
    @user.update_section_preferences("portfolio", order: %w[value_chart kpis])

    assert_equal %w[value_chart kpis performance realized_gains holdings accounts allocation data_quality],
                 registry.sections.map { |s| s[:key] }
  end

  test "a saved order that repeats a key renders that section once" do
    @user.update_section_preferences("portfolio", order: %w[value_chart kpis value_chart])

    keys = registry.sections.map { |s| s[:key] }

    assert_equal keys.uniq, keys
    assert_equal %w[value_chart kpis], keys.first(2)
  end

  test "ignores keys in the saved order that no longer exist" do
    @user.update_section_preferences("portfolio", order: %w[gone value_chart])

    assert_equal %w[value_chart kpis performance realized_gains holdings accounts allocation data_quality],
                 registry.sections.map { |s| s[:key] }
  end

  test "appends extra sections after the built-ins" do
    stub = {
      key: "stub",
      title: "portfolios.sections.kpis",
      partial: "portfolios/kpi_row",
      locals: { statement: @statement, period: @period, as_of: Date.current },
      visible: true,
      collapsible: true
    }

    sections = registry(extra_sections: [ stub ]).sections

    assert_equal "stub", sections.last[:key]
    assert_equal 9, sections.size
  end

  test "a saved order can place an extra section among the built-ins" do
    stub = { key: "stub", title: "portfolios.sections.kpis", partial: "portfolios/kpi_row",
             locals: {}, visible: true, collapsible: true }
    @user.update_section_preferences("portfolio", order: %w[stub kpis])

    assert_equal %w[stub kpis performance value_chart realized_gains holdings accounts allocation data_quality],
                 registry(extra_sections: [ stub ]).sections.map { |s| s[:key] }
  end

  # The bar chart's axis tick is `short_label`. Bare "%b" prints two identical
  # "Mar" ticks when a range spans more than one calendar year, so the year is
  # carried only when it has to be -- inside one year the bare month is what
  # fits the axis.
  test "axis ticks carry the year only when the buckets span more than one" do
    account = accounts(:investment)
    within_one_year = [ Date.new(2026, 3, 10), Date.new(2026, 5, 12) ]
    across_two = [ Date.new(2025, 3, 10), Date.new(2026, 3, 10) ]

    (within_one_year + across_two).uniq.each do |date|
      Holding.create!(account: account, security: securities(:aapl), date: date, qty: 10,
                      price: 150, amount: 1_500, currency: "USD",
                      cost_basis: 100, cost_basis_locked: true)
    end

    within_one_year.each { |date| sell_on(account, date) }
    @period = Period.custom(start_date: Date.new(2026, 1, 1), end_date: Date.new(2026, 12, 31))
    assert_equal %w[Mar May], bars.map { |bar| bar[:short_label] },
                 "one calendar year needs no year on the tick"

    across_two.each { |date| sell_on(account, date) }
    @period = Period.custom(start_date: Date.new(2025, 1, 1), end_date: Date.new(2026, 12, 31))
    assert_equal [ "Mar 25", "Mar 26", "May 26" ], bars.map { |bar| bar[:short_label] },
                 "two Marches in one chart have to be told apart"
  end

  private
    def bars
      registry.sections.find { |section| section[:key] == "realized_gains" }[:locals][:bars]
    end

    def sell_on(account, date)
      account.entries.create!(
        name: "Sell", date: date, amount: BigDecimal(300), currency: "USD",
        entryable: Trade.new(security: securities(:aapl), qty: -2, price: 150,
                             currency: "USD", investment_activity_label: "Sell")
      )
    end

    def registry(extra_sections: [])
      @as_of = Date.current
      Portfolio::SectionRegistry.new(
        statement: @statement,
        period: @period,
        as_of: @as_of,
        user: @user,
        extra_sections: extra_sections
      )
    end
end
