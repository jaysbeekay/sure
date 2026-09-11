require "test_helper"

class Portfolio::SectionRegistryTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @family = @user.family
    @period = Period.last_30_days
    @as_of = Date.current
    @statement = InvestmentStatement.new(@family, user: @user)
  end

  test "registers the six built-in sections with their partials and locals" do
    sections = registry.sections

    assert_equal %w[kpis value_chart holdings accounts allocation data_quality], sections.map { |s| s[:key] }
    assert_equal %w[portfolios/kpi_row portfolios/value_chart], sections.first(2).map { |s| s[:partial] }
    assert sections.all? { |s| s[:collapsible] }

    # Every partial gets its locals passed in: none of them reaches for
    # Date.current or Current.family on its own.
    sections.each do |section|
      assert_equal({ statement: @statement, period: @period, as_of: @as_of }, section[:locals].slice(:statement, :period, :as_of),
        "#{section[:key]} must receive the shared locals rather than reading them itself")
    end
  end

  test "sections are visible only when the family has data for them" do
    visible = registry.sections.select { |s| s[:visible] }.map { |s| s[:key] }
    assert_includes visible, "holdings"
    assert_includes visible, "accounts"
    assert_includes visible, "allocation"

    # A family with no investment accounts has nothing to list beyond the
    # always-on KPI row and chart (the controller shows the empty state).
    empty_statement = InvestmentStatement.new(families(:empty), user: nil)
    empty = Portfolio::SectionRegistry.new(statement: empty_statement, period: @period, as_of: @as_of, user: @user).sections
    assert_equal %w[kpis value_chart], empty.select { |s| s[:visible] }.map { |s| s[:key] }
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

    assert_equal %w[value_chart kpis holdings accounts allocation data_quality],
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

    assert_equal %w[value_chart kpis holdings accounts allocation data_quality],
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
    assert_equal 7, sections.size
  end

  test "a saved order can place an extra section among the built-ins" do
    stub = { key: "stub", title: "portfolios.sections.kpis", partial: "portfolios/kpi_row",
             locals: {}, visible: true, collapsible: true }
    @user.update_section_preferences("portfolio", order: %w[stub kpis])

    assert_equal %w[stub kpis value_chart holdings accounts allocation data_quality],
                 registry(extra_sections: [ stub ]).sections.map { |s| s[:key] }
  end

  private
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
