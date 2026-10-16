require "test_helper"

# Upstream's test/models/loan/payoff_chart_test.rb (we-promise/sure #3474,
# #4006), run against upstream's engine since #184's core swap. The fork adds
# the fourth series, `extra`, from the Extra repayments tab (#390), and keeps
# its own origination: `start_date` or the account's opening anchor.
class Loan::PayoffChartTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @today = Date.new(2027, 1, 15)
    # What the picker hands over for "All" on @today. The real all-time period
    # ends on Date.current, and these tests sit on a pinned date.
    @all_time = Period.new(key: "all_time", start_date: Date.new(2020, 1, 1), end_date: @today)
  end

  test "carries the recorded balance, the original schedule and the projection" do
    loan = on_contract_loan
    payload = Loan::PayoffChart.new(loan, as_of: @today).payload

    assert_not payload.key?(:accelerated), "the what-if left this tranche (#100 decision 10)"
    assert payload[:actual].length > 1
    assert payload[:scheduled].length > 1
    assert payload[:projected].length > 1
    assert_equal %w[actual scheduled projected], payload[:visible].map(&:to_s)
    assert_equal @today.iso8601, payload[:today]
    assert_equal "USD", payload[:currency]
  end

  # The amount borrowed is the first thing a payoff chart should show, and
  # every point after it is the schedule's own row for that date.
  test "the scheduled series is the schedule, opening at origination with the full principal" do
    loan = on_contract_loan
    payload = Loan::PayoffChart.new(loan, as_of: @today).payload
    rows = loan.amortization_schedule.payments.index_by { |row| row.date.iso8601 }

    assert_equal origination(loan).iso8601, payload[:scheduled].first[:date]
    assert_equal loan.amortization_schedule.principal.to_f, payload[:scheduled].first[:balance]
    payload[:scheduled].drop(1).each do |point|
      assert_equal rows.fetch(point[:date]).ending_balance.amount.to_f, point[:balance],
        "the scheduled point on #{point[:date]} must be the schedule's own row"
    end
    assert_equal rows.size, payload[:scheduled].size - 1
    assert_equal loan.amortization_schedule.payoff_date.iso8601, payload[:scheduled].last[:date]
  end

  # Risk R21: the chart plots the schedule the cards and the table read -- the
  # in-memory one -- never persisted rows a rate change has made stale.
  test "the scheduled series follows the current schedule when the persisted rows are stale" do
    loan = on_contract_loan
    loan.rebuild_amortization_schedule
    persisted = loan.reload.amortizations.ordered.map { |row| row.ending_balance.to_f }

    loan.update!(interest_rate: loan.interest_rate + 2)
    loan.reload
    assert_not loan.schedule_current?, "the persisted rows must be stale for this to mean anything"

    payload = Loan::PayoffChart.new(loan, as_of: @today).payload
    current = loan.amortization_schedule.payments.map { |row| row.ending_balance.amount.to_f }

    assert_not_equal persisted, current, "the rate change must move the schedule, or this proves nothing"
    assert_equal current, payload[:scheduled].drop(1).map { |point| point[:balance] }
    assert_not loan.schedule_current?, "drawing the chart must not rebuild the persisted rows"
  end

  test "the projection opens at today's real balance" do
    loan = on_contract_loan
    payload = Loan::PayoffChart.new(loan, as_of: @today).payload

    assert_equal @today.iso8601, payload[:projected].first[:date]
    assert_equal loan.account.balance.to_f, payload[:projected].first[:balance]
  end

  # #390 test 7: the endpoints the chart draws are the projections' own dates
  # for the same `as_of`, so the line and the cards that quote them agree.
  test "the projected and extra series end where the projections for the same as_of do" do
    loan = on_contract_loan
    baseline = Loan::PayoffProjection.new(loan, as_of: @today)
    extra = loan.payoff_projection_with_extra(amount: "2000", as_of: @today)
    assert_operator extra.payoff_date, :<, baseline.payoff_date, "the extra must shorten the loan, or this proves nothing"

    payload = Loan::PayoffChart.new(loan, as_of: @today, period: @all_time, extra_projection: extra).payload

    assert_equal baseline.payoff_date.iso8601, payload[:projected].last[:date]
    assert_equal baseline.payoff_date.iso8601, payload[:projected_payoff_date]
    assert_equal extra.payoff_date.iso8601, payload[:extra].last[:date]
    assert_equal extra.payoff_date.iso8601, payload[:extra_payoff_date]
    assert_equal @today.iso8601, payload[:extra].first[:date], "the extra line opens at today's balance too"
    assert_equal loan.account.balance.to_f, payload[:extra].first[:balance]
    assert_equal extra.payments.length + 1, payload[:extra].length
  end

  # #390 test 4 at the model level: the extra series exists only when an extra
  # projection was handed in, measured against the same chart without one.
  test "the extra series is carried only when an extra projection is given" do
    loan = on_contract_loan
    without = Loan::PayoffChart.new(loan, as_of: @today, period: @all_time).payload
    extra = loan.payoff_projection_with_extra(amount: "20000", as_of: @today)
    assert_not_equal Loan::PayoffProjection.new(loan, as_of: @today).payoff_date, extra.payoff_date,
      "the extra must move the payoff, or the description cannot tell the two apart"
    with = Loan::PayoffChart.new(loan, as_of: @today, period: @all_time, extra_projection: extra).payload

    assert_not without.key?(:extra)
    assert_not without.key?(:extra_payoff_date)
    assert_not_includes without[:visible].map(&:to_s), "extra"
    assert_not without[:labels].key?(:extra)

    assert with[:extra].length > 1
    assert_equal %w[actual scheduled projected extra], with[:visible].map(&:to_s)
    assert_equal I18n.t("UI.account.chart.loan.extra", amount: Money.new(20000, "USD").format), with[:labels][:extra]
    assert_includes with[:aria_description], I18n.l(extra.payoff_date, format: :long)
    assert_not_includes without[:aria_description], I18n.l(extra.payoff_date, format: :long)
  end

  test "an extra projection that never clears the loan adds no series" do
    loan = on_contract_loan
    extra = loan.payoff_projection_with_extra(amount: "250", as_of: @today)
    extra.stubs(:converged?).returns(false)

    payload = Loan::PayoffChart.new(loan, as_of: @today, extra_projection: extra).payload

    assert_not payload.key?(:extra)
    assert_not_includes payload[:visible].map(&:to_s), "extra"
  end

  # A period picked on a loan's chart means what it means on every other
  # chart: 90D is the last ninety days.
  # The recorded series runs from the window's start to today, and never before
  # origination. Queried past today it would carry today's balance forward as
  # a flat line.
  test "the actual series runs from the window's start to today, in the loan's currency" do
    loan = on_contract_loan

    whole_life = Loan::PayoffChart.new(loan, as_of: @today, period: @all_time).payload
    assert_equal @today.iso8601, whole_life[:actual].last[:date]
    assert_operator Date.iso8601(whole_life[:actual].first[:date]), :>=, origination(loan)

    window_start = @today - 90
    ninety_days = Period.new(key: "last_90_days", start_date: window_start, end_date: @today)
    clipped = Loan::PayoffChart.new(loan, as_of: @today, period: ninety_days).payload
    assert_equal window_start.iso8601, clipped[:actual].first[:date]
    assert_equal @today.iso8601, clipped[:actual].last[:date]
    assert clipped[:actual].all? { |point| Date.iso8601(point[:date]).between?(window_start, @today) }

    assert_equal "USD", clipped[:currency]
    assert_equal loan.account.balance.to_f, whole_life[:actual].last[:balance],
      "the recorded balance is read in the loan's own currency, so no exchange rate applies"
  end

  # #390 test 7: whatever the period reaches, the recorded series stops at
  # `as_of`. A period ending after it (a saved period read a day later, or a
  # pinned `as_of` behind the calendar) must not pull it forward.
  test "the actual series never passes as_of, even when the period does" do
    loan = on_contract_loan
    as_of = @today - 20
    reaching_past = Period.new(key: "all_time", start_date: Date.new(2020, 1, 1), end_date: @today + 30)

    payload = Loan::PayoffChart.new(loan, as_of: as_of, period: reaching_past).payload

    assert payload[:actual].any?
    assert payload[:actual].all? { |point| Date.iso8601(point[:date]) <= as_of },
      "a recorded point after as_of is the series builder carrying a balance forward"
    assert_equal as_of.iso8601, payload[:actual].last[:date]
  end

  # Under All the domain is the loan's whole life. Under a window it is the
  # period's own dates, opening no earlier than the loan: a 5Y window on a
  # one-year-old loan opens at origination.
  test "the domain is the whole life under All and the picked period otherwise, clamped at origination" do
    loan = on_contract_loan
    start = origination(loan)
    whole_life_end = [ loan.amortization_schedule.payoff_date, Loan::PayoffProjection.new(loan, as_of: @today).payoff_date ].max

    whole_life = Loan::PayoffChart.new(loan, as_of: @today, period: @all_time).payload
    assert_equal start.iso8601, whole_life[:domain_start]
    assert_equal whole_life_end.iso8601, whole_life[:domain_end]

    window_starts.each do |key, window_start|
      period = Period.new(key: key, start_date: window_start, end_date: @today)
      windowed = Loan::PayoffChart.new(loan, as_of: @today, period: period).payload
      expected_start = [ window_start, start ].max
      assert_equal expected_start.iso8601, windowed[:domain_start], "#{key} must open on #{expected_start}"
      assert_equal @today.iso8601, windowed[:domain_end], "#{key} must end today, where the period does"
    end
  end

  # A window ends today, so the projection has at most one point inside the
  # domain -- today -- and a point is not a line. The legend must not promise
  # one; All reaches past today and draws it.
  test "forward series are visible under All alone" do
    loan = on_contract_loan
    extra = loan.payoff_projection_with_extra(amount: "250", as_of: @today)

    window_starts.each do |key, window_start|
      period = Period.new(key: key, start_date: window_start, end_date: @today)
      windowed = Loan::PayoffChart.new(loan, as_of: @today, period: period, extra_projection: extra).payload
      assert_equal %w[actual scheduled], windowed[:visible].map(&:to_s), key
      assert windowed[:projected].length > 1, "the series is still in the payload; only its legend entry is withheld"
    end

    whole_life = Loan::PayoffChart.new(loan, as_of: @today, period: @all_time, extra_projection: extra).payload
    assert_includes whole_life[:visible].map(&:to_s), "projected"
    assert_includes whole_life[:visible].map(&:to_s), "extra"
  end

  # A loan drawn down years before the app tracked it -- a 2016 mortgage added
  # in 2024 -- must draw its recorded balance under every period it offers,
  # not the contract alone.
  test "an older loan whose history starts after origination draws recorded balances under every window" do
    loan = older_loan
    first_recorded = Date.new(2024, 1, 1)

    window_starts.each do |key, window_start|
      period = Period.new(key: key, start_date: window_start, end_date: @today)
      payload = Loan::PayoffChart.new(loan, as_of: @today, period: period).payload

      assert_equal [ window_start, origination(loan) ].max.iso8601, payload[:domain_start], key
      assert_equal @today.iso8601, payload[:domain_end], key
      assert_equal [ window_start, first_recorded ].max.iso8601, payload[:actual].first[:date],
        "#{key}: the recorded series starts where the window or the history does, whichever is later"
      assert_equal @today.iso8601, payload[:actual].last[:date], key
      assert_equal %w[actual scheduled], payload[:visible].map(&:to_s), "#{key}: both the recorded balance and the contract draw a line"
    end

    whole_life = Loan::PayoffChart.new(loan, as_of: @today, period: @all_time).payload
    assert_equal origination(loan).iso8601, whole_life[:domain_start]
    assert_equal first_recorded.iso8601, whole_life[:actual].first[:date]
    assert_equal %w[actual scheduled projected], whole_life[:visible].map(&:to_s)
  end

  # The picker's choice is shared with every account, so a loan page can be
  # opened under a period its chart does not offer. That shows the whole life.
  test "a saved period the loan chart does not offer shows the loan's whole life" do
    loan = on_contract_loan
    whole_life = Loan::PayoffChart.new(loan, as_of: @today, period: @all_time).payload

    %w[last_7_days last_30_days current_week last_month].each do |key|
      period = Period.new(key: key, start_date: @today - 30, end_date: @today)
      payload = Loan::PayoffChart.new(loan, as_of: @today, period: period).payload
      assert_equal whole_life.values_at(:domain_start, :domain_end), payload.values_at(:domain_start, :domain_end),
        "#{key} is not a loan window, so the chart shows the whole life"
    end
  end

  # WINDOW_KEYS is matched against the saved Period key. A key that is not a
  # real Period key would never match, and that window would silently show the
  # whole life instead.
  test "every loan window is a shared period key" do
    assert_empty Loan::PayoffChart::WINDOW_KEYS - Period::PERIODS.keys,
      "loan chart windows must use Period::PERIODS keys"
  end

  # Overlapping the schedule IS the on-track picture; the projection is not
  # withheld for agreeing with the contract.
  test "the projection is drawn when it overlaps the schedule and withheld only when it cannot run" do
    on_track = Loan::PayoffChart.new(on_contract_loan, as_of: @today).payload
    assert on_track[:projected].length > 1
    assert_includes on_track[:visible].map(&:to_s), "projected"

    cleared = build_loan
    cleared.account.update!(balance: 0)
    paid_off = Loan::PayoffChart.new(cleared.reload, as_of: @today).payload
    assert_empty paid_off[:projected]
    assert_not_includes paid_off[:visible].map(&:to_s), "projected"
  end

  # A loan drawn down today has one recorded point at most and no history to
  # compare against; the page must still render.
  test "a loan originated today renders a valid payload with no exception" do
    # Created on the pinned day itself: an origination date may not lie in the
    # future, and @today is ahead of the calendar.
    account = travel_to(@today) do
      account = Account.create!(
        family: @family, name: "New Loan", balance: 500_000, currency: "USD",
        accountable: Loan.new(subtype: "mortgage", interest_rate: 6, term_months: 24,
                              rate_type: "fixed", start_date: @today)
      )
      account.entries.create!(
        date: @today, name: "Opening balance", amount: 500_000, currency: "USD",
        entryable: Valuation.new(kind: "opening_anchor")
      )
      account
    end
    account.balances.delete_all
    account.balances.create!(date: @today, balance: 500_000, currency: "USD",
                             start_cash_balance: 500_000, flows_factor: -1)

    payload = Loan::PayoffChart.new(account.loan, as_of: @today, period: @all_time).payload

    assert_equal @today.iso8601, payload[:scheduled].first[:date]
    assert_equal @today.iso8601, payload[:domain_start]
    assert_operator payload[:actual].length, :<=, 1
    assert_not_includes payload[:visible].map(&:to_s), "actual", "one point is not a line"
    assert_includes payload[:visible].map(&:to_s), "projected"
  end

  test "no payload at all for a loan with no schedule" do
    loan = build_loan(rate_type: "")

    assert_nil Loan::PayoffChart.new(loan, as_of: @today).payload
  end

  test "a loan with no recorded balances yet draws no actual series and does not raise" do
    loan = build_loan
    loan.account.balances.delete_all

    payload = Loan::PayoffChart.new(loan.reload, as_of: @today).payload

    assert_empty payload[:actual]
    assert payload[:scheduled].length > 1
  end

  test "the accessible description names the balance and each payoff date separately" do
    loan = on_contract_loan
    payload = Loan::PayoffChart.new(loan, as_of: @today).payload
    schedule = loan.amortization_schedule
    projection = Loan::PayoffProjection.new(loan, as_of: @today)

    assert_includes payload[:aria_description], projection.current_balance.format
    assert_includes payload[:aria_description], I18n.l(schedule.payoff_date, format: :long)
    assert_includes payload[:aria_description], I18n.l(projection.payoff_date, format: :long)
    assert_not_includes payload[:aria_description], I18n.t(
      "UI.account.chart.loan.aria_actual_history_starts",
      date: I18n.l(origination(loan), format: :long)
    )
  end

  test "the accessible description dates recorded history when it starts after origination" do
    loan = on_contract_loan
    first_recorded_date = origination(loan) >> 6
    loan.account.balances.where(date: ...first_recorded_date).delete_all

    payload = Loan::PayoffChart.new(loan.reload, as_of: @today).payload

    assert_equal first_recorded_date.iso8601, payload[:actual].first[:date]
    assert_includes payload[:aria_description], I18n.t(
      "UI.account.chart.loan.aria_actual_history_starts",
      date: I18n.l(first_recorded_date, format: :long)
    )
  end

  test "German loan chart translations cover the English chart keys" do
    english = I18n.t("UI.account.chart.loan", locale: :en)
    german = I18n.t("UI.account.chart.loan", locale: :de, fallback: false)

    assert_equal english.keys.sort, german.keys.sort
    english.each do |key, value|
      assert_equal value.to_s.scan(/%\{\w+\}/).sort, german.fetch(key).to_s.scan(/%\{\w+\}/).sort,
        "placeholders differ for #{key}"
    end
  end

  # The chart controller sets aria-roledescription from labels.interactive_chart
  # and falls back to English when the payload does not carry it.
  test "the payload carries a localized interactive chart role description" do
    english = Loan::PayoffChart.new(on_contract_loan, as_of: @today).payload
    assert_equal "interactive chart", english[:labels][:interactive_chart]

    german = I18n.with_locale(:de) { Loan::PayoffChart.new(on_contract_loan, as_of: @today).payload }
    assert_equal "interaktives Diagramm", german[:labels][:interactive_chart]
  end

  # A repayment that no longer covers the interest has no payoff date. The
  # description must say so rather than interpolating a bare nil into a
  # sentence.
  test "the description says so when the repayment no longer pays the loan off" do
    loan = build_loan
    loan.account.update!(balance: 5_000_000)

    payload = Loan::PayoffChart.new(loan, as_of: @today).payload

    assert_nil payload[:projected_payoff_date]
    assert_empty payload[:projected], "a projection that never clears draws no line (#390)"
    assert_match I18n.t("UI.account.chart.loan.no_payoff"), payload[:aria_description]
    # The balloon travels with the payload; on a loan that does pay off it is
    # nil, so a figure of zero is never quoted.
    assert_operator payload[:balloon], :>, 0
    assert_nil Loan::PayoffChart.new(on_contract_loan, as_of: @today).payload[:balloon]
  end

  # Owner review of #3474: the chart has no data table; the Schedule tab
  # carries the figures, so the payload builds no rows for one.
  test "the payload carries no data table rows" do
    payload = Loan::PayoffChart.new(on_contract_loan, as_of: @today, period: @all_time).payload

    assert_not payload.key?(:rows), "nothing renders table rows, so the payload must not build them"
  end

  # The recorded series never starts before the loan does. A balance row dated
  # before origination must not become a lead-in, whatever window is picked.
  test "the actual series never starts before origination, whatever the window" do
    loan = on_contract_loan
    loan.account.balances.create!(date: Date.new(2025, 12, 1), balance: 0, currency: "USD",
                                  start_cash_balance: 0, flows_factor: -1)
    five_years = Period.new(key: "last_5_years", start_date: @today - 5.years, end_date: @today)

    [ @all_time, five_years ].each do |period|
      payload = Loan::PayoffChart.new(loan.reload, as_of: @today, period: period).payload

      assert_equal origination(loan).iso8601, payload[:actual].first[:date],
        "the first recorded point is origination, not the pre-origination row (#{period.key})"
      assert payload[:actual].none? { |point| Date.iso8601(point[:date]) < origination(loan) }
    end
  end

  test "the projected series ends on the projected payoff date" do
    loan = on_contract_loan
    payload = Loan::PayoffChart.new(loan, as_of: @today, period: @all_time).payload

    assert_equal payload[:projected_payoff_date], payload[:projected].last[:date]
    assert_equal payload[:scheduled_payoff_date], payload[:scheduled].last[:date]
  end

  # The layout hard-codes `lang="en"`, so the chart cannot learn the locale
  # from the document; the payload carries it for the tooltip's date and
  # money formatting.
  test "the payload carries the request locale for the tooltip" do
    loan = on_contract_loan

    assert_equal "en", Loan::PayoffChart.new(loan, as_of: @today).payload[:locale]
    I18n.with_locale(:de) do
      assert_equal "de", Loan::PayoffChart.new(loan, as_of: @today).payload[:locale]
    end
  end

  # The work the chart itself does must not grow with the length of the
  # schedule. The projection is built and run first, as the controller does
  # before handing it in: its simulation is PayoffProjection's own cost (it
  # reads the offset links once per simulated period), which the chart neither
  # adds to nor repeats, and which this test is not about.
  test "building the payload does not repeat its lookups per scheduled payment" do
    short = build_undated_loan(term_months: 24)
    long = build_undated_loan(term_months: 360)

    short_projection = run_projection(short)
    long_projection = run_projection(long)

    short_count = sql_statements { Loan::PayoffChart.new(short, as_of: @today, period: @all_time, projection: short_projection).payload }
    long_count = sql_statements { Loan::PayoffChart.new(long, as_of: @today, period: @all_time, projection: long_projection).payload }

    assert_equal short_count, long_count,
      "a 360-payment schedule ran #{long_count} statements where a 24-payment one ran #{short_count}"
  end

  # #21 / we-promise/sure#4006: the tooltip says what each scheduled payment is
  # made of. The figures are the schedule table's own rows, so the chart and the
  # Schedule tab cannot disagree.
  test "each scheduled payment point carries the payment's principal and interest" do
    loan = on_contract_loan
    payload = Loan::PayoffChart.new(loan, as_of: @today, period: @all_time).payload
    rows = loan.amortization_schedule.payments.index_by { |row| row.date.iso8601 }

    payments = payload[:scheduled].drop(1)
    assert_equal rows.size, payments.size
    payments.each do |point|
      row = rows.fetch(point[:date])
      assert_equal row.principal.amount.to_f, point[:principal], "principal on #{point[:date]}"
      assert_equal row.interest.amount.to_f, point[:interest], "interest on #{point[:date]}"
      assert_in_delta row.payment.amount.to_f, point[:principal] + point[:interest], 0.005,
        "the split on #{point[:date]} must add up to the payment"
    end
  end

  # The point of showing the split: early payments are mostly interest, late
  # ones mostly principal.
  test "the split on a long loan is interest-heavy at the start and principal-heavy at the end" do
    payments = Loan::PayoffChart.new(older_loan, as_of: @today, period: @all_time).payload[:scheduled].drop(1)

    assert_operator payments.first[:interest], :>, payments.first[:principal]
    assert_operator payments.last[:principal], :>, payments.last[:interest]
    assert_operator payments.first[:interest], :>, payments.last[:interest]
  end

  # Only contracted payments are split. The opening point is the amount
  # borrowed, not a payment, and the projections are forecasts.
  test "the opening point, the projections and the recorded balance carry no split" do
    loan = on_contract_loan
    extra = loan.payoff_projection_with_extra(amount: "250", as_of: @today)
    payload = Loan::PayoffChart.new(loan, as_of: @today, period: @all_time, extra_projection: extra).payload

    assert_not payload[:scheduled].first.key?(:principal)
    assert_not payload[:scheduled].first.key?(:interest)
    [ :projected, :extra, :actual ].each do |key|
      assert payload[key].any?, "#{key} must have points for this to mean anything"
      assert payload[key].none? { |point| point.key?(:principal) || point.key?(:interest) },
        "the #{key} series must not carry a split"
    end
  end

  test "the payload carries the loan currency's precision for the split" do
    loan = on_contract_loan
    assert_equal 2, Loan::PayoffChart.new(loan, as_of: @today).payload[:currency_precision]

    loan.account.update_columns(currency: "JPY")
    assert_equal 0, Loan::PayoffChart.new(loan.reload, as_of: @today).payload[:currency_precision]
  end

  # The tooltip names the figures with the Schedule tab's own column labels.
  test "the payload labels the split with the schedule table's own words" do
    payload = Loan::PayoffChart.new(on_contract_loan, as_of: @today).payload

    assert_equal I18n.t("loans.tabs.schedule.principal"), payload[:labels][:principal]
    assert_equal I18n.t("loans.tabs.schedule.interest"), payload[:labels][:interest]
  end

  # A variable loan's schedule is re-amortised at each recorded rate change
  # (C8); the scheduled line is that schedule, not the opening rate's.
  test "a variable loan's scheduled series is re-amortised at its recorded rate change" do
    loan = build_loan(rate_type: "variable")
    flat = Loan::PayoffChart.new(loan, as_of: @today, period: @all_time).payload[:scheduled]

    loan.update!(variable_rate_schedule: { "2026-06-01" => "9.0" })
    loan.reload
    changed = Loan::PayoffChart.new(loan, as_of: @today, period: @all_time).payload[:scheduled]
    rows = loan.amortization_schedule.payments

    assert_not_equal flat.map { |p| p[:balance] }, changed.map { |p| p[:balance] },
      "the rate change must move the scheduled line"
    assert_equal rows.map { |row| row.ending_balance.amount.to_f }, changed.drop(1).map { |p| p[:balance] }
  end

  # #21 AC#4, carried over from the payload this replaces: the accessible
  # description names the principal/interest composition the tooltip shows,
  # in the schedule table's own words.
  test "the accessible description names the principal and interest composition" do
    payload = Loan::PayoffChart.new(on_contract_loan, as_of: @today).payload

    assert_includes payload[:aria_description], I18n.t(
      "UI.account.chart.loan.aria_composition",
      principal: I18n.t("loans.tabs.schedule.principal"),
      interest: I18n.t("loans.tabs.schedule.interest")
    )
  end

  # Carried over from the payload this replaces: the forward lines step on the
  # loan's own payment dates, not on today's day of the month.
  test "the projection steps on the loan's next scheduled payment date, not today's day of the month" do
    as_of = Date.new(2026, 3, 20)
    loan = build_loan
    assert_equal 1, loan.start_date.day
    next_scheduled = loan.amortization_schedule.payments.map(&:date).find { |date| date > as_of }
    assert_not_equal as_of.next_month, next_scheduled, "the setup must separate the anchor from today's day"

    payload = Loan::PayoffChart.new(loan, as_of: as_of).payload

    assert_equal as_of.iso8601, payload[:projected].first[:date]
    assert_equal next_scheduled.iso8601, payload[:projected].second[:date]
  end

  private
    def origination(loan)
      loan.start_date || loan.account_opening_anchor_date
    end

    # Each bounded window the loan chart offers, with the start date the
    # shared Period gives it on @today. All is handled by @all_time.
    def window_starts
      {
        "current_month" => @today.beginning_of_month,
        "last_90_days" => @today - 90,
        "current_year" => @today.beginning_of_year,
        "last_365_days" => @today - 365,
        "last_5_years" => @today - 5.years,
        "last_10_years" => @today - 10.years
      }
    end

    def run_projection(loan)
      Loan::PayoffProjection.new(loan, as_of: @today).tap(&:payments)
    end

    # Every statement, including those the query cache answers: a cached
    # lookup still builds its relation and records.
    def sql_statements(&block)
      count = 0
      counter = ->(*, payload) { count += 1 unless payload[:name] == "SCHEMA" }
      ActiveSupport::Notifications.subscribed(counter, "sql.active_record", &block)
      count
    end

    # A loan with no recorded start date: origination falls back to the
    # account's opening anchor.
    def build_undated_loan(term_months:)
      account = Account.create!(
        family: @family, name: "Undated Loan #{SecureRandom.hex(4)}",
        balance: 500_000, currency: "USD",
        accountable: Loan.new(subtype: "mortgage", interest_rate: 6, term_months: term_months, rate_type: "fixed")
      )
      account.entries.create!(
        date: Date.new(2026, 1, 1), name: "Opening balance", amount: 500_000, currency: "USD",
        entryable: Valuation.new(kind: "opening_anchor")
      )
      record_balances(account)
      account.loan
    end

    def build_loan(rate_type: "fixed")
      account = Account.create!(
        family: @family, name: "Loan #{SecureRandom.hex(4)}",
        balance: 500_000, currency: "USD",
        accountable: Loan.new(subtype: "mortgage", interest_rate: 6, term_months: 24,
                              rate_type: rate_type, start_date: Date.new(2026, 1, 1))
      )
      # The opening valuation the account form records: Loan#original_balance
      # reads it, and without it the principal would follow whatever the
      # current balance is later set to.
      account.entries.create!(
        date: Date.new(2026, 1, 1), name: "Opening balance", amount: 500_000, currency: "USD",
        entryable: Valuation.new(kind: "opening_anchor")
      )
      record_balances(account)
      account.loan
    end

    # Loans exactly on contract at `@today`. The schedule then agrees with the
    # recorded history and the projection has somewhere to go.
    def on_contract_loan
      loan = build_loan
      scheduled = scheduled_balance_at(loan, @today)
      loan.account.update!(balance: scheduled)
      record_balances(loan.account, through: @today, closing: scheduled)
      loan.reload
    end

    # A thirty-year mortgage drawn down in 2016 and added to the app in 2024:
    # eight years of contract with no recorded balance, then history from
    # 2024 that follows the schedule, exactly on contract at `@today`.
    def older_loan
      origination = Date.new(2016, 1, 1)
      account = Account.create!(
        family: @family, name: "Old Loan #{SecureRandom.hex(4)}",
        balance: 500_000, currency: "USD",
        accountable: Loan.new(subtype: "mortgage", interest_rate: 6, term_months: 360,
                              rate_type: "fixed", start_date: origination)
      )
      account.entries.create!(
        date: origination, name: "Opening balance", amount: 500_000, currency: "USD",
        entryable: Valuation.new(kind: "opening_anchor")
      )
      scheduled = scheduled_balance_at(account.loan, @today)
      account.update!(balance: scheduled)
      record_balances(account, from: Date.new(2024, 1, 1), through: @today, closing: scheduled)
      account.loan.reload
    end

    def scheduled_balance_at(loan, date)
      loan.amortization_schedule.payments.select { |p| p.date <= date }.last.ending_balance.amount
    end

    # Materialised balance rows the way the balance calculator writes them for
    # a liability: the outstanding amount in start_cash_balance with a -1 flows
    # factor, which Balance::ChartSeriesBuilder reads back as a positive debt.
    # One row per scheduled payment from `from`, following the schedule's
    # balances so the recorded history is a plausible loan rather than a flat
    # line.
    def record_balances(account, from: Date.new(2026, 1, 1), through: Date.new(2026, 6, 30), closing: nil)
      account.balances.delete_all
      schedule_rows = account.loan.amortization_schedule&.payments || []
      opening = schedule_rows.select { |p| p.date <= from }.last&.ending_balance&.amount || 500_000
      rows = schedule_rows.select { |p| p.date > from && p.date <= through }
      account.balances.create!(date: from, balance: opening, currency: "USD",
                               start_cash_balance: opening, flows_factor: -1)
      rows.each do |row|
        account.balances.create!(date: row.date, balance: row.ending_balance.amount, currency: "USD",
                                 start_cash_balance: row.ending_balance.amount, flows_factor: -1)
      end
      return if closing.nil?

      account.balances.create!(date: through, balance: closing, currency: "USD",
                               start_cash_balance: closing, flows_factor: -1)
    end
end
