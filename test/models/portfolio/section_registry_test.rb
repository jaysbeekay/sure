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

    assert_equal %w[kpis performance index_chart value_chart accounts], Portfolio::SectionRegistry::KEYS
    assert_equal Portfolio::SectionRegistry::KEYS, sections.map { |s| s[:key] }
    assert_equal %w[portfolios/kpi_row portfolios/performance portfolios/index_chart portfolios/value_chart portfolios/accounts], sections.map { |s| s[:partial] }
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

  # nil is an outcome, not a gap: a figure whose rate is missing is
  # suppressed, as is one for an account with fewer than two balance days, and
  # the money-weighted return is withheld from a valuation-only scope. Passing nil through
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

  # The index is a level, not an amount: 121.34 means the portfolio returned
  # 21.34%. Series passes a non-Money value through untouched, which is what
  # lets the same chart controller draw it -- and is also what would let a
  # Money slip in unnoticed, so the payload is asserted rather than assumed.
  test "the index chart series carries rebased levels, not money" do
    perf = Portfolio::Performance.new(family: @family, account_ids: [], period: @period)
    perf.stubs(:index_series).returns([
      [ Date.new(2026, 3, 1), BigDecimal("100") ],
      [ Date.new(2026, 3, 2), BigDecimal("110") ],
      [ Date.new(2026, 3, 3), BigDecimal("121.34") ]
    ])
    @statement.stubs(:performance).returns(perf)

    section = registry.sections.find { |s| s[:key] == "index_chart" }

    assert section[:visible]
    values = section[:locals][:series].values
    assert_equal 3, values.size
    assert_equal BigDecimal("121.34"), values.last.value
    assert_not values.any? { |v| v.value.is_a?(Money) }, "an index level is not money"

    # Rounded before it reaches the wire. A chained level is a division result,
    # and nothing downstream rounds it: the hover would otherwise read
    # 112.30000000000000000000000000000311.
    # Built the way Portfolio::Performance builds it -- chained DIVISION
    # results, not a literal -- because that is what produces the long value.
    # Verified: this is 112.30000000000000000000000000000311, 32 places.
    r1 = (BigDecimal(1037) / BigDecimal(1000)) - 1
    r2 = (BigDecimal(1123) / BigDecimal(1037)) - 1
    chained = BigDecimal(100) * (1 + r1) * (1 + r2)
    assert_operator chained.to_s.split(".").last.length, :>, 4,
                    "the fixture must actually be long, or this test proves nothing"

    long = Portfolio::Performance.new(family: @family, account_ids: [], period: @period)
    long.stubs(:index_series).returns([
      [ Date.new(2026, 3, 1), BigDecimal("100") ],
      [ Date.new(2026, 3, 2), chained ]
    ])
    @statement.stubs(:performance).returns(long)

    serialised = registry.sections.find { |s| s[:key] == "index_chart" }[:locals][:series].to_json
    assert_no_match(/\d+\.\d{4,}/, serialised,
                    "a level reaches the tooltip with two decimals, not thirty")
  end

  # from_raw_values demands two points, and a period with one day or none has
  # no line to draw. An empty chart says nothing the performance cards above
  # have not already said, so the section hides rather than drawing a blank box.
  test "the index chart section hides when there is no line to draw" do
    perf = Portfolio::Performance.new(family: @family, account_ids: [], period: @period)
    perf.stubs(:index_series).returns([ [ Date.new(2026, 3, 1), BigDecimal("100") ] ])
    @statement.stubs(:performance).returns(perf)

    section = registry.sections.find { |s| s[:key] == "index_chart" }

    assert_not section[:visible]
    assert_nil section[:locals][:series]
  end

  test "the accounts section is visible only when the family has investment accounts" do
    assert registry.sections.find { |s| s[:key] == "accounts" }[:visible]

    empty_statement = InvestmentStatement.new(families(:empty), user: nil)
    empty = Portfolio::SectionRegistry.new(statement: empty_statement, period: @period, as_of: @as_of, user: @user).sections
    assert_not empty.find { |s| s[:key] == "accounts" }[:visible]
  end

  # The KPI row, the performance cards and the value chart speak for
  # themselves when empty: each says there is not enough data rather than
  # disappearing. (The controller shows the whole-page empty state anyway.)
  test "the KPI row, the performance cards and the value chart stay visible for a family with no data" do
    empty_statement = InvestmentStatement.new(families(:empty), user: nil)
    empty = Portfolio::SectionRegistry.new(statement: empty_statement, period: @period, as_of: @as_of, user: @user).sections

    assert_equal %w[kpis performance value_chart], empty.select { |s| s[:visible] }.map { |s| s[:key] }
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

    assert_equal %w[stub kpis performance index_chart value_chart accounts], registry(extra_sections: [ stub_section ]).sections.map { |s| s[:key] }
  end

  test "a saved order that repeats a key renders that section once" do
    @user.update_section_preferences("portfolio", order: %w[stub accounts stub])

    keys = registry(extra_sections: [ stub_section ]).sections.map { |s| s[:key] }

    assert_equal %w[stub accounts kpis performance index_chart value_chart], keys
  end

  test "ignores keys in the saved order that no longer exist" do
    @user.update_section_preferences("portfolio", order: %w[gone accounts])

    assert_equal %w[accounts kpis performance index_chart value_chart], registry.sections.map { |s| s[:key] }
  end

  test "appends extra sections after the built-ins" do
    sections = registry(extra_sections: [ stub_section ]).sections

    assert_equal %w[kpis performance index_chart value_chart accounts stub], sections.map { |s| s[:key] }
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
