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

    assert_equal %w[kpis value_chart accounts], Portfolio::SectionRegistry::KEYS
    assert_equal Portfolio::SectionRegistry::KEYS, sections.map { |s| s[:key] }
    assert_equal %w[portfolios/kpi_row portfolios/value_chart portfolios/accounts], sections.map { |s| s[:partial] }
    assert sections.all? { |s| s[:collapsible] }

    # Every partial gets its locals passed in: none of them reaches for
    # Date.current or Current.family on its own.
    sections.each do |section|
      assert_equal({ statement: @statement, period: @period, as_of: @as_of }, section[:locals].slice(:statement, :period, :as_of),
        "#{section[:key]} must receive the shared locals rather than reading them itself")
    end
  end

  test "the accounts section is visible only when the family has investment accounts" do
    assert registry.sections.find { |s| s[:key] == "accounts" }[:visible]

    empty_statement = InvestmentStatement.new(families(:empty), user: nil)
    empty = Portfolio::SectionRegistry.new(statement: empty_statement, period: @period, as_of: @as_of, user: @user).sections
    assert_not empty.find { |s| s[:key] == "accounts" }[:visible]
  end

  # The KPI row and the value chart speak for themselves when empty: each says
  # there is not enough data rather than disappearing. (The controller shows
  # the whole-page empty state anyway.)
  test "the KPI row and the value chart stay visible for a family with no data" do
    empty_statement = InvestmentStatement.new(families(:empty), user: nil)
    empty = Portfolio::SectionRegistry.new(statement: empty_statement, period: @period, as_of: @as_of, user: @user).sections

    assert_equal %w[kpis value_chart], empty.select { |s| s[:visible] }.map { |s| s[:key] }
  end

  # Every period-dependent figure reads the registry's period. A custom range
  # differs from every default, so a figure that fell back to one would show.
  test "the KPI row and the value chart read the registry's period" do
    period = Period.custom(start_date: 10.days.ago.to_date, end_date: 3.days.ago.to_date)
    # The fixture's figures are the same for any period, so these three are
    # pinned by the argument they are asked with rather than by their value.
    trend = Trend.new(current: Money.new(110, "USD"), previous: Money.new(100, "USD"))
    totals = @statement.totals(period: period)
    @statement.expects(:period_return_trend).with(period: period).returns(trend)
    @statement.expects(:period_return_unconvertible_count).with(period: period).returns(2)
    # net_contributions reads totals for the same period, hence at least once.
    @statement.expects(:totals).with(period: period).at_least_once.returns(totals)

    sections = registry(period: period).sections.index_by { |s| s[:key] }
    kpis = sections["kpis"][:locals][:kpis]

    assert_same trend, kpis[:period_return]
    assert_equal 2, kpis[:period_return_unconvertible]
    assert_equal totals.total_income, kpis[:income]
    assert_equal @statement.net_contributions(period: period), kpis[:net_contributions]
    assert_equal @statement.value_series(period: period).values.size, sections["value_chart"][:locals][:series].values.size
    assert_equal period.end_date, sections["value_chart"][:locals][:series].values.last.date
  end

  test "the KPI row carries the statement's current figures" do
    kpis = registry.sections.find { |s| s[:key] == "kpis" }[:locals][:kpis]

    assert_equal @statement.portfolio_value_money, kpis[:value]
    assert_equal %i[value day_change unrealized period_return period_return_unconvertible net_contributions income], kpis.keys
  end

  # Created in reverse name order, so the cards come back by name only if the
  # query asks for it.
  test "the accounts section lists the cards in name order" do
    zeta = @family.accounts.create!(name: "Zeta brokerage", balance: 100, currency: "USD", accountable: Investment.new, owner: @user)
    alpha = @family.accounts.create!(name: "Alpha brokerage", balance: 100, currency: "USD", accountable: Investment.new, owner: @user)
    @statement = InvestmentStatement.new(@family, user: @user)

    cards = registry.sections.find { |s| s[:key] == "accounts" }[:locals][:accounts]

    assert_includes cards, zeta
    assert_operator cards.index(alpha), :<, cards.index(zeta)
    assert_equal @statement.investment_accounts.to_a.sort_by(&:id), cards.sort_by(&:id),
      "the cards must be exactly the statement's investment accounts"
  end

  test "orders sections by the user's saved order, appending anything it omits" do
    @user.update_section_preferences("portfolio", order: %w[stub])

    assert_equal %w[stub kpis value_chart accounts], registry(extra_sections: [ stub_section ]).sections.map { |s| s[:key] }
  end

  test "a saved order that repeats a key renders that section once" do
    @user.update_section_preferences("portfolio", order: %w[stub accounts stub])

    keys = registry(extra_sections: [ stub_section ]).sections.map { |s| s[:key] }

    assert_equal %w[stub accounts kpis value_chart], keys
  end

  test "ignores keys in the saved order that no longer exist" do
    @user.update_section_preferences("portfolio", order: %w[gone accounts])

    assert_equal %w[accounts kpis value_chart], registry.sections.map { |s| s[:key] }
  end

  test "appends extra sections after the built-ins" do
    sections = registry(extra_sections: [ stub_section ]).sections

    assert_equal %w[kpis value_chart accounts stub], sections.map { |s| s[:key] }
  end

  private
    def stub_section
      { key: "stub", title: "portfolios.sections.accounts", partial: "portfolios/accounts",
        locals: {}, visible: true, collapsible: true }
    end

    def registry(extra_sections: [], period: @period)
      Portfolio::SectionRegistry.new(
        statement: @statement,
        period: period,
        as_of: @as_of,
        user: @user,
        extra_sections: extra_sections
      )
    end
end
