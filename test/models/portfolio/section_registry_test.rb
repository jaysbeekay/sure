require "test_helper"

class Portfolio::SectionRegistryTest < ActiveSupport::TestCase
  include PortfolioReturnsTestHelper
  setup do
    @user = users(:family_admin)
    @family = @user.family
    @period = Period.last_30_days
    @as_of = Date.current
    @statement = InvestmentStatement.new(@family, user: @user)
  end

  test "registers the built-in sections with their partials and locals" do
    sections = registry.sections

    assert_equal %w[kpis performance index_chart comparison drivers value_chart realized_gains holdings accounts allocation data_quality], sections.map { |s| s[:key] }
    assert_equal %w[portfolios/kpi_row portfolios/performance portfolios/index_chart portfolios/comparison], sections.first(4).map { |s| s[:partial] }
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

  # R7 reports fees as a POSITIVE magnitude that REDUCES the change, and R12's
  # identity subtracts it:
  #
  #   external_net + composition + income - fees + market + revaluations
  #     + fx_effect == value_close - value_open
  #
  # A table that rendered each component as given would show fees ADDING to the
  # portfolio, and would not sum to the change printed beneath it. The signing
  # is a contract rule, so it lives in the registry, and this is what pins it.
  test "the drivers table signs fees against the change, and reconciles" do
    drivers = stub_drivers(value_open: 1_000, value_close: 1_150,
                           external_net: 100, income: 30, fees: 20, market: 40)
    perf = Portfolio::Performance.new(family: @family, account_ids: [], period: @period)
    perf.stubs(:drivers).returns(drivers)
    @statement.stubs(:performance).returns(perf)

    contributions = registry.sections.find { |s| s[:key] == "drivers" }[:locals][:contributions]

    assert_equal(-BigDecimal(20), contributions.to_h[:fees], "fees reduce the change, so they render negative")
    assert_equal BigDecimal(100), contributions.to_h[:external_net]

    # The row that matters: what the table shows must add up to what it says
    # the change was.
    assert_equal BigDecimal(150), contributions.sum { |_key, amount| amount }
    assert_equal drivers[:change], contributions.sum { |_key, amount| amount }

    # The local that drives the "these figures do not reconcile" alert. Without
    # asserting it, a broken driver_reconciles? could invert the alert while
    # every assertion above stayed green.
    assert registry.sections.find { |s| s[:key] == "drivers" }[:locals][:reconciles],
           "a decomposition that adds up reports as reconciled"
  end

  # A period with no fees does not need a fees row saying zero, and
  # `unexplained` is expected to be zero -- it is measured rather than defined
  # so, which is why a NON-zero one has to be shown rather than swallowed.
  test "the drivers table drops zero components but keeps a real unexplained" do
    quiet = stub_drivers(value_open: 1_000, value_close: 1_100, market: 100)
    perf = Portfolio::Performance.new(family: @family, account_ids: [], period: @period)
    perf.stubs(:drivers).returns(quiet)
    @statement.stubs(:performance).returns(perf)

    keys = registry.sections.find { |s| s[:key] == "drivers" }[:locals][:contributions].map(&:first)
    assert_equal [ :market ], keys, "a period with only market movement lists only market"

    noisy = stub_drivers(value_open: 1_000, value_close: 1_100, market: 90, unexplained: 10)
    perf2 = Portfolio::Performance.new(family: @family, account_ids: [], period: @period)
    perf2.stubs(:drivers).returns(noisy)
    @statement.stubs(:performance).returns(perf2)

    section = registry.sections.find { |s| s[:key] == "drivers" }
    keys = section[:locals][:contributions].map(&:first)
    assert_includes keys, :unexplained, "a measured gap must be shown, not folded away"
    assert_not section[:locals][:reconciles],
               "and the table says so, rather than leaving the reader to spot the row"
  end

  # R12 defines reconciliation at a CENT, not at exact zero, and a
  # multi-currency scope accumulates sub-cent residue by construction: entry
  # flows convert entry -> family at t-1 while balance-row flows went
  # entry -> account at the entry date and then account -> family.
  #
  # At exact zero a residual of 0.004 would raise the "these figures do not
  # reconcile" banner and print an "Unexplained $0.00" row -- a gap the figure
  # itself denies.
  test "a sub-cent residual reconciles and is not listed" do
    drivers = stub_drivers(value_open: 1_000, value_close: 1_100, market: 100,
                           unexplained: BigDecimal("0.004"))
    perf = Portfolio::Performance.new(family: @family, account_ids: [], period: @period)
    perf.stubs(:drivers).returns(drivers)
    @statement.stubs(:performance).returns(perf)

    section = registry.sections.find { |s| s[:key] == "drivers" }

    assert section[:locals][:reconciles], "a sub-cent residual is what the contract calls reconciled"
    assert_not_includes section[:locals][:contributions].map(&:first), :unexplained,
                        "and a row that rounds to nothing says nothing"
  end

  # The other side of the boundary: a residual ABOVE the cent is a real gap and
  # must still be shown, so the tolerance cannot quietly swallow a finding.
  test "a residual above the tolerance is still reported" do
    drivers = stub_drivers(value_open: 1_000, value_close: 1_100, market: 90,
                           unexplained: BigDecimal("10"))
    perf = Portfolio::Performance.new(family: @family, account_ids: [], period: @period)
    perf.stubs(:drivers).returns(drivers)
    @statement.stubs(:performance).returns(perf)

    section = registry.sections.find { |s| s[:key] == "drivers" }

    assert_not section[:locals][:reconciles]
    assert_includes section[:locals][:contributions].map(&:first), :unexplained
  end

  # The two tests above sit at 0.004 and at 10, so nothing between them is
  # pinned: with those fixtures alone, changing `<=` to `<` passes, and so does
  # widening the tolerance to half a unit. The boundary is the claim the
  # constant makes, so the boundary is what is asserted -- a residual exactly at
  # one cent reconciles, and one a thousandth above it does not.
  test "the reconcile boundary is the cent itself, inclusive" do
    assert_equal BigDecimal("0.01"), Portfolio::Drivers::RECONCILE_TOLERANCE,
                 "the figure itself, not whatever the constant says: it is one minor unit " \
                 "of a two-decimal currency, and a wider one would swallow a real gap"

    [ [ BigDecimal("0.01"), true ],
      [ BigDecimal("0.011"), false ] ].each do |residual, expected|
      drivers = stub_drivers(value_open: 1_000, value_close: 1_100,
                             market: BigDecimal(100) - residual, unexplained: residual)
      perf = Portfolio::Performance.new(family: @family, account_ids: [], period: @period)
      perf.stubs(:drivers).returns(drivers)
      @statement.stubs(:performance).returns(perf)

      section = registry.sections.find { |s| s[:key] == "drivers" }

      assert_equal expected, section[:locals][:reconciles],
                   "a residual of #{residual.to_s('F')} must #{expected ? '' : 'not '}reconcile"
      assert_equal expected, section[:locals][:contributions].map(&:first).exclude?(:unexplained),
                   "and the row must #{expected ? 'not ' : ''}be listed with it"
    end
  end

  # The section and Portfolio::Drivers both decide what "reconciles" means --
  # the section re-derives it from `unexplained` because Performance caches
  # `drivers.to_h` rather than the object -- and the two literals had already
  # drifted once, exact zero here against a cent there, so the table called a
  # period unreconciled while the model called it reconciled. They read one
  # constant now, and this fails if either grows its own again.
  test "the section and the drivers model reconcile at the same figures" do
    [ BigDecimal("0.01"), BigDecimal("0.011") ].each do |residual|
      drivers = stub_drivers(value_open: 1_000, value_close: 1_100,
                             market: BigDecimal(100) - residual, unexplained: residual)
      perf = Portfolio::Performance.new(family: @family, account_ids: [], period: @period)
      perf.stubs(:drivers).returns(drivers)
      @statement.stubs(:performance).returns(perf)

      model = Portfolio::Drivers.allocate
      model.stubs(:unexplained).returns(residual)

      assert_equal model.reconciles?, registry.sections.find { |s| s[:key] == "drivers" }[:locals][:reconciles],
                   "the table and the model must agree at a residual of #{residual.to_s('F')}"
    end
  end

  # B2, and it is a GIPS point rather than a preference. Each account's line is
  # computed with ITS OWN id as the scope, not the wider portfolio: money moved
  # from account A to account B is internal to the portfolio and a CONTRIBUTION
  # to B. A line labelled "B" has to answer "what did B return", so B's scope
  # is B. Passing the wider scope would keep the transfer internal and report
  # the arriving money as B's investment return -- the same defect class as
  # #151, one level up.
  test "each comparison line is scoped to its own account, not the portfolio" do
    create_portfolio_account(family: @family, name: "Second")
    built = []

    Portfolio::Performance.stubs(:new).with do |args|
      built << args
      true
    end.returns(stub_index_performance)

    registry.send(:comparison_series)

    lines = built.select { |args| args[:account_ids].size == 1 }
    assert lines.any?, "each line is built from a single account"

    # The assertion is about scope_account_ids, NOT account_ids. Widening the
    # scope is exactly what DailyReturns documents as the way to keep internal
    # transfers internal, so a test that only checked account_ids would pass
    # against the mistake it exists to prevent -- which the first version of
    # this test did.
    lines.each do |args|
      scope = args[:scope_account_ids]
      assert scope.nil? || scope == args[:account_ids],
             "a line named for one account must not be scoped to the whole portfolio: " \
             "money moved from another account is a contribution to this one, not its return"
    end
  end

  # D7's cap, and the reason it exists: each line costs one
  # Portfolio::Performance, so an uncapped comparison would make the page's cost
  # grow with the number of accounts a family holds.
  test "the comparison plots at most five accounts plus the whole portfolio" do
    7.times { |i| create_portfolio_account(family: @family, name: "Acct #{i}") }
    Portfolio::Performance.any_instance.stubs(:index_series).returns(two_points)

    series = registry.send(:comparison_series)

    assert_operator series.size, :<=, Portfolio::SectionRegistry::COMPARISON_LIMIT + 1
    assert_equal I18n.t("portfolios.comparison.whole_portfolio"), series.first[:label],
                 "the portfolio is the baseline the others are read against, so it is drawn first"
  end

  # The comment on the section says it is hidden when there is nothing to
  # compare, and the predicate said `size > 1` -- which one account satisfies,
  # because the baseline is a line too. The whole portfolio and its only account
  # are the same series: the aggregate Performance and the per-account one are
  # built over the same holdings, so the reader gets two identical lines and a
  # legend implying they differ.
  test "a family with a single account gets no comparison section" do
    only = create_portfolio_account(family: @family, name: "Only broker")
    @statement.stubs(:historical_scope).returns(
      stub(accounts: [ only ], account_ids: [ only.id ], active_until_dates: {})
    )
    Portfolio::Performance.any_instance.stubs(:index_series).returns(two_points)

    series = registry.send(:comparison_series)
    assert_equal 2, series.size, "the premise: a baseline and the one account under it"

    comparison = registry.sections.find { |section| section[:key] == "comparison" }
    assert_not comparison[:visible],
               "one account against the portfolio it is the entirety of compares nothing"
  end

  # The levels reach the browser inside a `data-...-series-value` attribute, one
  # per point per line, up to six lines. A chained level is a BigDecimal
  # division result and nothing downstream trims it, so unrounded they are ~35
  # digits each. index_chart_series already rounds for the same reason.
  test "comparison levels are serialised rounded, not at BigDecimal's full width" do
    create_portfolio_account(family: @family, name: "Second broker")
    long = [ [ Date.new(2026, 1, 1), BigDecimal(100) ],
             [ Date.new(2026, 1, 2), BigDecimal(1_000) / BigDecimal(7) ] ]
    Portfolio::Performance.any_instance.stubs(:index_series).returns(long)

    values = registry.send(:comparison_series).flat_map { |line| line[:values].map { |point| point[:value] } }

    assert values.any?, "the fixture has to actually draw lines"
    values.each do |value|
      assert_operator value.to_s("F").split(".").last.length, :<=, 2,
                      "#{value} reaches the attribute with more than two decimal places"
    end
  end

  # Deterministic selection: name breaks a tie, so the plotted set does not
  # depend on whatever order the database returns.
  test "accounts of equal value are chosen by name, not by database order" do
    %w[Zeta Alpha].each { |name| create_portfolio_account(family: @family, name: name) }
    Portfolio::Performance.any_instance.stubs(:index_series).returns(two_points)

    chosen = registry.send(:comparison_accounts).map(&:name)

    # Both new accounts hold nothing, as do the fixture accounts, so every
    # value is zero and NAME is the only thing separating them. Asserted
    # unconditionally: if either ever dropped out of the selection this should
    # fail loudly rather than skip itself.
    assert_includes chosen, "Alpha"
    assert_includes chosen, "Zeta"
    assert_operator chosen.index("Alpha"), :<, chosen.index("Zeta"),
                    "equal value ties break alphabetically, not by insertion order"
  end

  # A closed broker keeps its history in the aggregate -- that is what
  # historical_scope is for -- but it must not spend one of the five comparison
  # slots. It would rank on its large final balance, then lose its line to the
  # two-point guard, and a live account would go undrawn for it.
  test "an account closed before the period end does not take a comparison slot" do
    closed = create_portfolio_account(family: @family, name: "Closed broker")
    @statement.stubs(:historical_scope).returns(
      stub(accounts: [ closed ], account_ids: [ closed.id ],
           active_until_dates: { closed.id => @period.date_range.end - 5 })
    )

    assert_empty registry.send(:comparison_accounts),
                 "an account whose cut-off predates the period end is not a candidate"
  end

  # The palette is written twice -- once in Ruby for the legend, once in JS for
  # the lines -- and a legend that disagrees with its chart mislabels every
  # series. The comment on COMPARISON_COLORS promises this test; it now exists.
  test "the legend palette matches the chart controller's, in order" do
    js = Rails.root.join("app/javascript/controllers/time_series_chart_controller.js").read
    block = js[/static SERIES_COLORS = \[(.*?)\]/m, 1]
    assert block, "SERIES_COLORS not found in the controller"

    from_js = block.scan(/"([^"]+)"/).flatten

    assert_equal PortfoliosHelper::COMPARISON_COLORS, from_js,
                 "the legend and the chart must draw the same colours in the same order"
  end

  # A series colour has to be readable on the surface the chart is drawn on, and
  # in dark mode that surface IS gray-900: `_generated.css` sets
  # `--color-container: var(--color-gray-900)` under `[data-theme="dark"]`, and
  # the section wrapper is `bg-container`. The baseline -- the line every other
  # line is read against -- was `var(--color-gray-900)`, which has no dark
  # override, so it was #171717 drawn on #171717, and its legend dot with it.
  #
  # Read out of the stylesheet rather than hard-coded, so that a later change to
  # what `--color-container` resolves to is caught here instead of going dark
  # again silently.
  test "no series colour is the container's own colour in dark mode" do
    css = Rails.root.join("app/assets/tailwind/sure-design-system/_generated.css").read
    dark = css[/\[data-theme="dark"\]\s*\{(.*?)^  \}/m, 1]
    assert dark, "the dark theme block was not found in the design system"

    container = dark[/--color-container:\s*([^;]+);/, 1]&.strip
    assert_equal "var(--color-gray-900)", container,
                 "the premise: in dark mode a container is painted gray-900"

    assert_not_includes PortfoliosHelper::COMPARISON_COLORS, container,
                        "a line painted the container's own colour is an invisible line"
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
    # `performance` joins kpis and value_chart as always-on: a period with no
    # computable figure is a fact worth stating, where a vanishing section
    # reads as "this page does not do returns".
    assert_equal %w[kpis performance value_chart], empty.select { |s| s[:visible] }.map { |s| s[:key] }
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

    assert_equal %w[value_chart kpis performance index_chart comparison drivers realized_gains holdings accounts allocation data_quality],
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

    assert_equal %w[value_chart kpis performance index_chart comparison drivers realized_gains holdings accounts allocation data_quality],
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
    assert_equal 12, sections.size
  end

  test "a saved order can place an extra section among the built-ins" do
    stub = { key: "stub", title: "portfolios.sections.kpis", partial: "portfolios/kpi_row",
             locals: {}, visible: true, collapsible: true }
    @user.update_section_preferences("portfolio", order: %w[stub kpis])

    assert_equal %w[stub kpis performance index_chart comparison drivers value_chart realized_gains holdings accounts allocation data_quality],
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

    # A Portfolio::Drivers whose components are whatever the test names, so a
    # table test does not depend on building balance history that produces
    # exactly the split it wants to assert.
    # The shape Portfolio::Performance#drivers actually returns: the HASH from
    # Portfolio::Drivers#to_h, not the object. It caches its metrics, so the
    # object cannot survive the round trip -- which is also why `reconciles?`
    # is absent and the registry re-derives it from `unexplained`.
    def stub_drivers(value_open:, value_close:, external_net: 0, composition: 0,
                     income: 0, fees: 0, market: 0, revaluations: 0,
                     fx_effect: 0, unexplained: 0)
      {
        value_open: value_open, value_close: value_close,
        change: value_close - value_open, external_net: external_net,
        composition: composition, income: income, fees: fees, market: market,
        revaluations: revaluations, fx_effect: fx_effect, unexplained: unexplained
      }.transform_values { |value| BigDecimal(value.to_s) }
    end

    def two_points
      [ [ Date.new(2026, 3, 1), BigDecimal("100") ], [ Date.new(2026, 3, 2), BigDecimal("110") ] ]
    end

    def stub_index_performance
      perf = Portfolio::Performance.allocate
      perf.stubs(:index_series).returns(two_points)
      perf
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
