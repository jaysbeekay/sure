require "test_helper"

class Loan::PayoffProjectionTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @today = Date.new(2027, 1, 15)
  end

  test "a loan exactly on contract projects the schedule it is already on" do
    loan = build_loan(term_months: 24)
    on_contract = scheduled_balance_at(loan, @today)
    loan.account.update!(balance: on_contract)

    projection = loan.payoff_projection(as_of: @today)

    assert projection.applicable?
    assert projection.converged?
    assert_equal loan.amortization_schedule.payoff_date, projection.payoff_date
    assert_equal 0, projection.months_saved
  end

  # Extra payments already made need no input of their own: they are why the
  # recorded balance sits below the scheduled one, and the projection starts
  # from that balance (#100, decision 10).
  test "an overpaid loan finishes early and pays less interest, with no extra-payment input" do
    loan = build_loan(term_months: 24)
    loan.account.update!(balance: scheduled_balance_at(loan, @today) - 50_000)

    projection = loan.payoff_projection(as_of: @today)

    assert projection.converged?
    assert_operator projection.months_saved, :>, 0
    assert_operator projection.interest_saved.amount, :>, 0
    assert_operator projection.payoff_date, :<, loan.amortization_schedule.payoff_date
  end

  # Decision 1 on #100. A variable loan that is ahead keeps paying what the
  # contract currently asks and therefore finishes early. Re-amortising the
  # smaller balance would shrink the repayment and land it back on the
  # original maturity, which is what this test exists to refuse.
  test "a variable loan ahead of schedule pays the contract's repayment and finishes early" do
    loan = build_loan(term_months: 24, rate_type: "variable")
    loan.update!(variable_rate_schedule: { Date.new(2026, 7, 1).iso8601 => "12.0" })
    loan.account.update!(balance: scheduled_balance_at(loan, @today) - 30_000)
    loan.reload

    projection = loan.payoff_projection(as_of: @today)
    schedule_by_date = loan.amortization_schedule.payments.index_by(&:date)

    projection.payments[0..-2].each do |payment|
      assert_equal schedule_by_date.fetch(payment[:payment_date]).payment.amount, payment[:payment_amount],
        "on #{payment[:payment_date]} the projection must pay what the contract asks, not a re-sized figure"
    end
    assert_operator projection.payoff_date, :<, loan.amortization_schedule.payoff_date
    assert_operator projection.months_saved, :>, 0
  end

  # A variable loan's CONTRACT resizes the repayment at each rate change, and
  # the projection follows the schedule's own resized figure -- not one
  # re-derived from the balance in front of it.
  test "a future recorded rate change moves the projected repayment by the schedule's amount" do
    loan = build_loan(term_months: 24, rate_type: "variable")
    change_date = @today >> 3
    loan.update!(variable_rate_schedule: { change_date.iso8601 => "18.0" })
    loan.account.update!(balance: scheduled_balance_at(loan, @today) - 20_000)
    loan.reload

    projection = loan.payoff_projection(as_of: @today)
    schedule_by_date = loan.amortization_schedule.payments.index_by(&:date)
    first_resized = projection.payments.find { |p| p[:payment_date] >= change_date }

    assert_operator first_resized[:payment_amount], :>, projection.payments.first[:payment_amount],
      "the repayment must resize when the recorded rate rises"
    assert_equal schedule_by_date.fetch(first_resized[:payment_date]).payment.amount, first_resized[:payment_amount],
      "and it resizes to the schedule's figure, not to one sized from the smaller balance"
  end

  # On a fixed loan every scheduled row carries the same repayment, so paying
  # the schedule's rows is the held contracted payment. Byte-identical to a
  # :hold run seeded with that payment, which pins that decision 1 changed
  # nothing for fixed loans.
  #
  # Fork: the held run is given what the projection is given -- its first
  # period opening where the schedule's does, and the loan's interest
  # calculation -- since under daily accrual a period's length is part of its
  # charge, where upstream's monthly charge is the same from any opening day.
  test "a fixed loan's projection is identical to holding the contracted payment" do
    loan = build_loan(term_months: 24)
    loan.account.update!(balance: scheduled_balance_at(loan, @today) - 10_000)
    loan.reload
    projection = loan.payoff_projection(as_of: @today)
    schedule = loan.amortization_schedule
    remaining = schedule.payments.select { |p| p.date > @today }
    resolver = Loan::RateResolver.for(loan)

    held = Loan::Simulator.new(
      starting_balance: loan.account.balance,
      accrual_start_date: schedule.payments.select { |p| p.date <= @today }.last.date,
      payment_schedule: remaining.map(&:date),
      accrual_rate_for: resolver.method(:accrual_rate_for),
      re_amortisation_events: resolver.method(:re_amortisation_events),
      payment_amount: remaining.first.payment.amount,
      payment_strategy: :hold,
      currency_precision: 2,
      settle_at_schedule_end: false,
      interest_for: Loan::DailyInterest.for(loan)
    ).run

    assert_equal held.payments, projection.payments
  end

  # The case that was unreachable in #103, and the reason convergence came back
  # with this change. A borrower far enough behind is not paying the loan off on
  # the contracted repayment -- and must not be shown a payoff date implying
  # otherwise.
  #
  # Fork (#401): a loan behind schedule is followed past maturity on its last
  # level repayment, so upstream's 400,000 clears a year late here. What never
  # clears is a balance the repayment cannot keep pace with: 22,160.28 a month
  # against 6% on 5,000,000 is less than the interest.
  test "a loan too far behind to clear reports a balloon and no payoff date" do
    loan = build_loan(term_months: 24)
    loan.account.update!(balance: 5_000_000)

    projection = loan.payoff_projection(as_of: @today)

    assert projection.applicable?
    assert_not projection.converged?
    assert_nil projection.payoff_date
    assert_operator projection.balloon_amount.amount, :>, 0
    assert_equal 0, projection.months_saved, "no months are saved by a loan that never finishes"
  end

  # CodeRabbit on #3474: `accounts.balance` is nullable and Money.new(nil)
  # raises, and the Schedule tab reads the projection outside the chart's
  # rescue. A loan with no balance yet has nothing to project.
  test "a loan with no balance yet is not applicable rather than raising" do
    loan = build_loan(term_months: 24)
    loan.account.update_columns(balance: nil)

    projection = loan.payoff_projection(as_of: @today)

    assert_not projection.applicable?
    assert_nil projection.payoff_date
    assert_equal 0, projection.current_balance.amount
  end

  # Fork divergence (#401). Upstream stops at maturity, so a loan even
  # slightly behind never converges there and a converged projection never
  # adds interest. The fork follows it past maturity on the last level
  # repayment: it finishes late, and the Schedule tab's "interest added" card
  # says what that costs.
  test "a loan slightly behind finishes after maturity on the last level repayment" do
    loan = build_loan(term_months: 24)
    loan.account.update!(balance: scheduled_balance_at(loan, @today) + 500)

    projection = loan.payoff_projection(as_of: @today)

    assert projection.applicable?
    assert projection.converged?
    assert_operator projection.payoff_date, :>, loan.amortization_schedule.payoff_date
    assert_operator projection.months_saved, :<, 0
    assert_operator projection.interest_saved.amount, :<, 0
  end

  test "is not applicable to a loan with no schedule or nothing left to owe" do
    unamortizable = build_loan(term_months: 24, rate_type: "")
    assert_not unamortizable.payoff_projection(as_of: @today).applicable?

    cleared = build_loan(term_months: 24)
    cleared.account.update!(balance: 0)
    assert_not cleared.payoff_projection(as_of: @today).applicable?

    # Fork (#401): a matured loan still owing is followed on its last level
    # repayment rather than dropped, so maturity alone does not end the
    # projection; nothing left to owe does.
    matured = build_loan(term_months: 24)
    matured.account.update!(balance: 0)
    assert_not matured.payoff_projection(as_of: Date.new(2040, 1, 1)).applicable?
  end


  # A variable loan's CONTRACT resizes the repayment at each rate change.
  # Holding one figure to maturity projects a repayment the lender will never
  # ask for, and the further out the change, the more wrong the payoff date.
  test "a variable projection re-amortises at a recorded rate change" do
    loan = build_loan(term_months: 24, rate_type: "variable")
    loan.update!(variable_rate_schedule: { (@today >> 3).iso8601 => "18.0" })
    loan.account.update!(balance: scheduled_balance_at(loan, @today))
    projection = loan.reload.payoff_projection(as_of: @today)

    before = projection.payments.first[:payment_amount]
    after = projection.payments.find { |p| p[:payment_date] >= (@today >> 3) }[:payment_amount]

    assert_operator after, :>, before,
      "the repayment must resize when the recorded rate rises"
  end

  # The comparison the cards quote: a balance recorded on a scheduled date,
  # equal to the schedule's balance for that date, saves nothing. The
  # projection's first period then charges exactly what the schedule's next
  # row charges, so `interest_saved` is zero, not merely small.
  test "a loan exactly on contract saves no interest" do
    loan = build_loan(term_months: 24)
    on_date = loan.amortization_schedule.payments.find { |p| p.date > @today }.date
    loan.account.update!(balance: loan.amortization_schedule.payments.find { |p| p.date == on_date }.ending_balance.amount)

    projection = loan.reload.payoff_projection(as_of: on_date)

    assert_equal 0, projection.months_saved
    assert_equal BigDecimal("0"), projection.interest_saved.amount
  end

  # Under monthly accrual a period is charged at the rate in force when it
  # OPENED (Loan::Simulator's class comment), so a change recorded between the
  # last payment and today belongs to the next period. Opening the projection's
  # first period at `as_of` instead re-rated the month already running, and a
  # variable borrower exactly on contract was quoted interest the schedule
  # never charges.
  test "a rate change between the last payment and today does not re-rate the month already running" do
    loan = build_loan(term_months: 24, rate_type: "variable")
    last_paid = loan.amortization_schedule.payments.select { |p| p.date <= @today }.last.date
    change_date = last_paid + 5
    assert_operator change_date, :<, @today, "the change must fall inside the period already running"

    loan.update!(variable_rate_schedule: { change_date.iso8601 => "12.0" })
    # Fresh records: the schedule read above is memoised without the change.
    loan.account.update!(balance: scheduled_balance_at(Loan.find(loan.id), @today))
    projection = Loan.find(loan.id).payoff_projection(as_of: @today)

    assert projection.converged?
    assert_equal 0, projection.months_saved
    assert_equal BigDecimal("0"), projection.interest_saved.amount,
      "on contract, the projection must charge the running month what the schedule charges it"
  end

  # ---------------------------------------------------------------------------
  # Fork: the projection's daily interest, offsets, the past-maturity window
  # (#401), the Extra repayments what-if (#304) and the injected date (#89,
  # #184). Everything above is upstream's projection suite; the three tests
  # whose premise is upstream's stop-at-maturity say how the fork differs.
  # ---------------------------------------------------------------------------

  # CodeRabbit, #89: the projection used to read `Date.current` for its start
  # and its cutoff. A year of difference in the injected date must move the
  # count of contracted payments still ahead of it.
  test "the injected as_of anchors the projection" do
    loan = fork_loan(balance: 400_762.12, interest_rate: 6.18, start_date: Date.current - 83.months)

    today = Loan::PayoffProjection.new(loan, as_of: Date.current)
    next_year = Loan::PayoffProjection.new(loan.reload, as_of: Date.current + 1.year)

    assert_operator next_year.send(:remaining_payment_dates).length, :<, today.send(:remaining_payment_dates).length,
      "a later as_of must leave fewer contracted payments ahead of it"
    assert_equal Date.current, today.as_of
    assert_equal Date.current + 1.year, next_year.as_of
  end

  # #184 (2026-10-01, note 1): the projection's offsets split recorded history
  # from today's total held flat at the projection's own date, not the wall
  # clock's.
  test "the injected as_of reaches the offset balances" do
    loan = fork_loan(balance: 500_000, rate_type: "variable")
    offset = @family.accounts.create!(name: "Dated offset", balance: 50_000, currency: "USD", accountable: Depository.new)
    loan.loan_offset_accounts.create!(account: offset)
    as_of = Date.current - 40.days

    Loan::OffsetResolver.expects(:new).with(loan, as_of: as_of).returns(stub(change_points: []))

    Loan::PayoffProjection.new(loan, as_of: as_of).payments
  end

  test "charges through the loan's daily interest on the loan's day-count basis" do
    loan = fork_loan(balance: 400_000)
    loan.update!(day_count_convention: "actual_actual")

    Loan::Simulator.expects(:new).with do |kwargs|
      kwargs[:interest_for].is_a?(Loan::DailyInterest) && kwargs[:interest_for].day_count_convention == "actual_actual"
    end.returns(stub(run: Loan::SimulationResult.new(payments: [], currency_precision: 2)))

    Loan::PayoffProjection.new(loan).payments
  end

  # C4: the first period opens where the schedule's period containing as_of
  # opened, charged on today's balance -- not a stub from as_of, which left the
  # days since the last payment uncharged and read an on-contract borrower as
  # ahead. On contract mid-period, the projection is the schedule's own tail.
  test "the first projected period opens where the schedule's does, not on as_of" do
    loan = fork_loan(balance: 500_000, start_date: Date.new(2025, 1, 15))
    loan.update!(day_count_convention: "actual_365")
    loan = Loan.find(loan.id)
    as_of = Date.new(2026, 3, 27)
    rows = loan.amortization_rows
    on_contract = rows.select { |row| row[:payment_date] <= as_of }.last
    loan.account.update!(balance: on_contract[:ending_balance])

    projection = Loan.find(loan.id).payoff_projection(as_of: as_of)
    following = rows.find { |row| row[:payment_date] > as_of }

    assert_equal following[:interest_payment], projection.payments.first[:interest_payment],
      "the period running on as_of is charged in full, from the last payment date"
    assert_equal 0, projection.months_saved
    assert_equal BigDecimal("0"), projection.interest_saved.amount
  end

  test "projecting neither needs persisted rows nor writes them" do
    loan = fork_loan(balance: 500_000)
    loan.account.update!(balance: 450_000)
    loan.amortizations.delete_all

    assert_no_difference -> { LoanAmortization.count } do
      assert Loan.find(loan.id).payoff_projection.converged?
    end
  end

  test "a linked offset reduces projected interest without reducing the loan balance" do
    offset = @family.accounts.create!(name: "Projection offset", balance: 50_000, currency: "USD", accountable: Depository.new)
    loan = fork_loan(balance: 500_000)
    loan.loan_offset_accounts.create!(account: offset)
    loan.account.update!(balance: 450_000)

    with_offset = loan.payoff_projection
    with_offset_interest = with_offset.total_interest.amount
    offset.update!(balance: 0)
    without_offset = loan.reload.payoff_projection

    assert_operator with_offset_interest, :<, without_offset.total_interest.amount
    assert_operator with_offset.payoff_date, :<, without_offset.payoff_date
    assert_equal BigDecimal("450000"), with_offset.current_balance.amount
    assert_equal BigDecimal("450000"), without_offset.current_balance.amount
  end

  test "an empty linked offset preserves the no-offset projection" do
    loan = fork_loan(balance: 500_000)
    baseline = loan.payoff_projection
    offset = @family.accounts.create!(name: "Empty offset", balance: 0, currency: "USD", accountable: Depository.new)
    loan.loan_offset_accounts.create!(account: offset)

    with_empty_offset = loan.reload.payoff_projection

    assert_equal baseline.payoff_date, with_empty_offset.payoff_date
    assert_equal baseline.total_interest.amount, with_empty_offset.total_interest.amount
  end

  # On contract at drawdown, the projection IS the schedule: the fork's old
  # stub-from-as_of projection trailed by a rounding "cleanup" payment here,
  # which upstream's period-start opening removed.
  test "an untouched loan projects its own schedule" do
    drawdown = Date.new(2026, 6, 15)
    loan = fork_loan(balance: 500_000, start_date: drawdown)

    projection = Loan::PayoffProjection.new(loan, as_of: drawdown)

    assert projection.converged?
    assert_equal 0, projection.months_saved
    assert_equal BigDecimal("0"), projection.interest_saved.amount
    assert_not projection.diverges_from_schedule?
  end

  # #257: the projected calendar is the contracted calendar, including for a
  # month-end start, and from any point in the loan.
  test "the projected calendar is the contracted calendar, for a month-end start and mid-loan" do
    drawdown = Date.new(2026, 9, 29)
    loan = fork_loan(balance: 500_000, start_date: drawdown)
    contracted = loan.amortization_schedule.payments.map(&:date)

    [ drawdown, drawdown + 2.months, drawdown + 40.months ].each do |as_of|
      ahead = contracted.select { |date| date > as_of }
      projected = Loan::PayoffProjection.new(loan, as_of: as_of).send(:projected_payment_dates)

      assert_equal ahead, projected.first(ahead.length), "the calendars must agree from #{as_of}"
    end
  end

  test "an on-contract month-end loan does not read as diverging" do
    [ Date.new(2026, 9, 29), Date.new(2026, 9, 30), Date.new(2026, 3, 31) ].each do |drawdown|
      loan = fork_loan(balance: 500_000, start_date: drawdown)
      projection = Loan::PayoffProjection.new(loan, as_of: drawdown)

      assert_not projection.diverges_from_schedule?, "a loan drawn down on #{drawdown} sits on its own contract"
      assert_equal BigDecimal("0"), projection.interest_saved.amount
    end
  end

  # #189 reaching the projection: a rate change between two payment dates is
  # charged from its own date in the projection as in the schedule.
  test "a rate change between payment dates moves the projection's interest, not just the schedule's" do
    loan = fork_loan(balance: 500_000, rate_type: "variable")
    payment_dates = loan.amortization_schedule.payments.map(&:date).select { |date| date > Date.current }
    mid_period = payment_dates.first + ((payment_dates.second - payment_dates.first) / 2)
    assert mid_period > payment_dates.first && mid_period < payment_dates.second,
      "test setup must place the rate change strictly inside a payment period"

    baseline_interest = loan.payoff_projection.total_interest.amount
    loan.update!(variable_rate_schedule: { mid_period.iso8601 => 4.5 })
    changed = Loan.find(loan.id).payoff_projection

    assert changed.converged?, "test setup must keep the loan clearing, or the comparison below is vacuous"
    assert_operator changed.total_interest.amount, :>, baseline_interest,
      "raising the rate part-way through a period must raise projected interest"
  end

  # A loan a cent behind settles in one tiny payment past maturity: rounding,
  # not a divergence worth a card. A loan a few dollars behind pays real
  # interest for it, and that is shown.
  test "a cent behind is not a divergence, but a real shortfall is" do
    as_of = Date.new(2026, 6, 15)
    cent = fork_loan(balance: 500_000, start_date: as_of)
    cent.account.update!(balance: 500_000.01)
    trailing = Loan.find(cent.id).payoff_projection(as_of: as_of)

    assert_equal(-1, trailing.months_saved, "precondition: the loan trails by exactly one payment")
    assert_not trailing.diverges_from_schedule?

    dollars = fork_loan(balance: 500_000, start_date: as_of)
    dollars.account.update!(balance: 500_005)
    behind = Loan.find(dollars.id).payoff_projection(as_of: as_of)

    assert_equal(-1, behind.months_saved)
    assert_operator behind.interest_saved.amount, :<=, -1
    assert behind.diverges_from_schedule?
  end

  test "projects a sooner payoff and positive interest saved when ahead of schedule" do
    loan = fork_loan(balance: 500_000)
    loan.account.update!(balance: 450_000)

    projection = loan.payoff_projection

    assert projection.converged?
    assert_operator projection.months_saved, :>, 0
    assert projection.interest_saved.positive?
    assert_operator projection.payoff_date, :<, loan.amortization_schedule.payoff_date
    assert_equal loan.amortization_schedule.periodic_payment, projection.monthly_payment
  end

  test "projects a later payoff and negative interest saved when behind schedule" do
    loan = fork_loan(balance: 500_000)
    loan.account.update!(balance: 550_000)

    projection = loan.payoff_projection

    assert projection.converged?
    assert_operator projection.months_saved, :<, 0
    assert projection.interest_saved.negative?
  end

  test "nothing is projected when the current balance is fully paid off" do
    loan = fork_loan(balance: 500_000)
    loan.account.update!(balance: 0)

    projection = loan.payoff_projection

    assert_not projection.applicable?
    assert_not projection.converged?
    assert_nil projection.payoff_date
    assert_equal 0, projection.months_saved
    assert_equal BigDecimal("0"), projection.interest_saved.amount
    assert_equal [], projection.payments
  end

  # Changes on two exact payment dates: each is charged from the period that
  # opens on it (interest_rate) and sizes the payment it lands on
  # (sizing_rate).
  test "projects a variable rate loan using rates effective in each payment period" do
    loan = fork_loan(balance: 500_000, rate_type: "variable")
    payment_dates = loan.amortization_schedule.payments.map(&:date).select { |date| date > Date.current }
    loan.update!(variable_rate_schedule: { payment_dates[1].iso8601 => 4.5, payment_dates[3].iso8601 => 5.5 })
    loan.account.update!(balance: 450_000)

    projection = Loan.find(loan.id).payoff_projection

    assert projection.converged?
    assert_equal %w[3.5 3.5 4.5 4.5 5.5].map { |rate| BigDecimal(rate) },
      projection.payments.first(5).map { |payment| payment[:interest_rate] }
    assert_equal %w[3.5 4.5 4.5 5.5 5.5].map { |rate| BigDecimal(rate) },
      projection.payments.first(5).map { |payment| payment[:sizing_rate] }
  end

  # #100, decision 1: the extra rides on top of the contract's repayment for
  # each period, so a recorded change resizes the what-if where it resizes
  # the schedule.
  test "extra-payment projection applies recorded variable rates to the scheduled repayment" do
    loan = fork_loan(balance: 500_000, rate_type: "variable")
    payment_dates = loan.amortization_schedule.payments.map(&:date).select { |date| date > Date.current }
    loan.update!(variable_rate_schedule: { payment_dates[1].iso8601 => 4.5, payment_dates[3].iso8601 => 5.5 })
    loan.account.update!(balance: 450_000)
    loan = Loan.find(loan.id)
    extra_payment = Loan::PayoffProjection.monthly_equivalent(amount: 200, frequency: "monthly", currency: "USD")

    projection = Loan::PayoffProjection.new(loan, extra_payment: extra_payment)

    assert projection.converged?
    schedule = loan.amortization_schedule.payments.index_by(&:date)
    projection.payments.first(5).each do |payment|
      assert_equal schedule.fetch(payment[:payment_date]).payment.amount + extra_payment.amount, payment[:payment_amount]
    end
  end

  test "a repayment that no longer covers the interest never clears the loan" do
    loan = fork_loan(balance: 500_000)
    # 2,245.22 a month no longer covers 3.5% once the balance passes ~769,790.
    loan.account.update!(balance: 800_000)

    projection = loan.payoff_projection

    assert projection.applicable?
    assert_not projection.converged?
    assert_nil projection.payoff_date
  end

  test "zero interest rate projects a straight-line payoff" do
    loan = fork_loan(balance: 120_000, interest_rate: 0, term_months: 120)
    loan.account.update!(balance: 100_000)

    projection = loan.payoff_projection

    assert projection.converged?
    assert_operator projection.months_saved, :>, 0
    assert_equal BigDecimal("0"), projection.total_interest.amount
  end

  # The first projected payment falls on the loan's own next payment date, not
  # on today's day-of-month.
  test "anchors the first projected payment on the loan's actual next scheduled payment date" do
    travel_to Date.new(2026, 3, 20) do
      loan = fork_loan(balance: 500_000, start_date: 2.years.ago.to_date.change(day: 15))
      loan.account.update!(balance: 450_000)

      next_scheduled_date = loan.amortization_schedule.payments.find { |payment| payment.date > Date.current }.date
      assert_not_equal Date.current.next_month, next_scheduled_date, "test setup should exercise a real anchor mismatch"

      assert_equal next_scheduled_date, loan.payoff_projection.payments.first[:payment_date]
    end
  end

  # A repayment that only barely covers the first period's interest can take
  # far longer than the window to clear. The window ends without a payoff date
  # rather than reporting the last date walked as one.
  test "a run that does not clear within the window reports no payoff" do
    loan = fork_loan(balance: 100_000, interest_rate: 5.0, term_months: 12)
    payment = loan.amortization_schedule.periodic_payment.amount
    threshold_balance = payment / (BigDecimal("5.0") / 100 / 12)
    loan.account.update!(balance: (threshold_balance * BigDecimal("0.995")).round(2))

    projection = loan.payoff_projection

    assert projection.applicable?
    assert_not projection.converged?
    assert_nil projection.payoff_date
    assert_equal 0, projection.months_saved
    assert_equal BigDecimal("0"), projection.interest_saved.amount
    assert_equal 2 * 12, projection.payment_count, "the window is twice the term, and it was walked to its end"
  end

  test "Loan#payoff_projection reads the balance afresh on every call" do
    loan = fork_loan(balance: 500_000)

    first = loan.payoff_projection
    assert_equal Money.new(500_000, "USD"), first.current_balance

    loan.account.update!(balance: 450_000)
    second = loan.payoff_projection

    assert_not_same first, second
    assert_equal Money.new(450_000, "USD"), second.current_balance
  end

  test "an extra payment shortens the payoff and increases interest saved beyond the baseline" do
    loan = fork_loan(balance: 500_000)
    baseline = loan.payoff_projection

    boosted = Loan::PayoffProjection.new(
      loan, extra_payment: Loan::PayoffProjection.monthly_equivalent(amount: 200, frequency: "monthly", currency: "USD")
    )

    assert boosted.converged?
    assert_operator boosted.months_saved, :>, baseline.months_saved
    assert_operator boosted.interest_saved.amount, :>, baseline.interest_saved.amount
    assert_equal baseline.monthly_payment + Money.new(200, "USD"), boosted.monthly_payment
  end

  # #304: what paying extra saves against NOT paying it, not the distance from
  # the contract. On a loan already ahead the two differ.
  test "interest saved versus a baseline is what the extra buys, not the distance from the contract" do
    loan = fork_loan(balance: 500_000)
    loan.account.update!(balance: 450_000)
    as_of = Date.current

    baseline = Loan::PayoffProjection.new(loan, as_of: as_of)
    extra = loan.payoff_projection_with_extra(amount: "200", as_of: as_of)

    expected = baseline.total_interest.amount - extra.total_interest.amount
    assert_operator expected, :>, 0
    assert_equal expected, extra.interest_saved_versus(baseline)
    assert_not_equal extra.interest_saved.amount, extra.interest_saved_versus(baseline),
      "against the contract the figure also counts the $50k already paid ahead"

    assert_equal baseline.payment_count - extra.payment_count, extra.months_sooner_than(baseline)
    assert_operator extra.months_sooner_than(baseline), :>, 0
    assert_not_equal extra.months_saved, extra.months_sooner_than(baseline)
  end

  test "a comparison against itself saves nothing" do
    baseline = Loan::PayoffProjection.new(fork_loan(balance: 500_000))

    assert_equal 0, baseline.interest_saved_versus(baseline)
    assert_equal 0, baseline.months_sooner_than(baseline)
  end

  test "the comparison is nil when either side never clears the loan" do
    loan = loan_whose_contracted_payment_no_longer_covers_interest
    baseline = Loan::PayoffProjection.new(loan)
    assert_not baseline.converged?

    extra = loan.payoff_projection_with_extra(amount: "100000")
    assert extra.converged?, "a large enough extra makes the loan amortise"

    assert_nil extra.interest_saved_versus(baseline)
    assert_nil extra.months_sooner_than(baseline)
  end

  test "payoff_projection_with_extra models a monthly amount on the injected date" do
    loan = fork_loan(balance: 500_000)
    as_of = Date.current + 1.month

    extra = loan.payoff_projection_with_extra(amount: "200", as_of: as_of)

    assert_equal as_of, extra.as_of
    assert_equal loan.amortization_schedule.periodic_payment + Money.new(200, "USD"), extra.monthly_payment
  end

  test "an extra larger than the remaining balance pays the loan off at the next payment" do
    extra = fork_loan(balance: 500_000).payoff_projection_with_extra(amount: "600000")

    assert extra.converged?
    assert_equal 1, extra.payment_count
    assert_equal 0, extra.payments.last[:ending_balance]
  end

  test "a blank or zero extra payment behaves identically to no extra payment" do
    loan = fork_loan(balance: 500_000)
    baseline = loan.payoff_projection

    blank = Loan::PayoffProjection.new(loan, extra_payment: nil)
    zero = Loan::PayoffProjection.new(loan, extra_payment: Money.new(0, "USD"))

    assert_equal baseline.monthly_payment, blank.monthly_payment
    assert_equal baseline.monthly_payment, zero.monthly_payment
    assert_equal baseline.payoff_date, blank.payoff_date
    assert_equal baseline.payoff_date, zero.payoff_date
  end

  test "monthly_equivalent normalizes weekly and yearly amounts to a monthly figure" do
    assert_equal Money.new(BigDecimal("50") * 52 / 12, "USD"),
      Loan::PayoffProjection.monthly_equivalent(amount: 50, frequency: "weekly", currency: "USD")
    assert_equal Money.new(100, "USD"),
      Loan::PayoffProjection.monthly_equivalent(amount: 100, frequency: "monthly", currency: "USD")
    assert_equal Money.new(BigDecimal("1200") / 12, "USD"),
      Loan::PayoffProjection.monthly_equivalent(amount: 1200, frequency: "yearly", currency: "USD")
  end

  test "monthly_equivalent returns nil for a blank, zero, non-numeric or non-finite amount" do
    [ nil, "", 0, "not-a-number", "NaN", "Infinity", "-Infinity" ].each do |raw|
      assert_nil Loan::PayoffProjection.monthly_equivalent(amount: raw, frequency: "monthly", currency: "USD"),
        "#{raw.inspect} must not become a Money amount that can reach the simulator"
    end
  end

  test "monthly_equivalent raises on an unsupported frequency" do
    assert_raises(ArgumentError) do
      Loan::PayoffProjection.monthly_equivalent(amount: 50, frequency: "fortnightly", currency: "USD")
    end
  end

  test "monthly_equivalent still accepts ordinary amounts" do
    money = Loan::PayoffProjection.monthly_equivalent(amount: "50", frequency: "weekly", currency: "USD")

    assert_predicate money.amount, :finite?
    assert_in_delta 216.67, money.amount.to_f, 0.01, "50/week is 50 * 52 / 12 monthly-equivalent"
  end

  # The what-if is offered where the baseline repayment never clears the loan:
  # that is when someone most wants to model paying more.
  test "eligible_for_extra_payment? is true even when the baseline repayment never clears the loan" do
    loan = fork_loan(balance: 500_000)
    loan.account.update!(balance: 800_000)

    assert_not loan.payoff_projection.converged?
    assert Loan::PayoffProjection.eligible_for_extra_payment?(loan)
  end

  test "eligibility and applicability agree about rate type" do
    %w[fixed variable].each do |rate_type|
      loan = fork_loan(balance: 500_000, rate_type: rate_type)
      loan.account.update!(balance: 450_000)

      assert_equal loan.payoff_projection.applicable?, Loan::PayoffProjection.eligible_for_extra_payment?(loan),
        "#{rate_type}: neither may gate on rate type without the other (#54)"
    end
  end

  test "eligible_for_extra_payment? is false when the balance is already zero" do
    loan = fork_loan(balance: 500_000)
    loan.account.update!(balance: 0)

    assert_not Loan::PayoffProjection.eligible_for_extra_payment?(loan)
  end

  # #401: a matured loan still owing is followed on its last level repayment
  # rather than dropped, while the lender quotes no minimum for it.
  test "a matured loan still owing is projected on its last level repayment" do
    loan = matured_loan_still_carrying_a_balance
    schedule = loan.amortization_schedule

    assert_operator schedule.payoff_date, :<, Date.current, "the fixture must actually be matured"
    assert_nil loan.current_minimum_payment, "past maturity there is no minimum to quote"

    projection = loan.payoff_projection
    assert projection.converged?
    assert_equal schedule.payments[-2].payment, projection.monthly_payment
  end

  private
    # Built the way the account form builds one: with an opening valuation for
    # the amount borrowed. `Loan#original_balance` reads it; without it the
    # principal follows whatever the current balance is later set to, and a
    # schedule read after a balance update would amortise a different loan.
    def build_loan(term_months:, rate_type: "fixed", interest_rate: 6)
      account = Account.create!(
        family: @family, name: "Loan #{SecureRandom.hex(4)}",
        balance: 500_000, currency: "USD",
        accountable: Loan.new(subtype: "mortgage", interest_rate: interest_rate,
                              term_months: term_months, rate_type: rate_type,
                              start_date: Date.new(2026, 1, 1))
      )
      account.entries.create!(
        date: Date.new(2026, 1, 1), name: "Opening balance", amount: 500_000, currency: "USD",
        entryable: Valuation.new(kind: "opening_anchor")
      )
      account.loan
    end

    def scheduled_balance_at(loan, date)
      loan.amortization_schedule.payments
        .select { |p| p.date <= date }.last.ending_balance.amount
    end

    # A loan whose opening valuation pins `Loan#original_balance`, so later
    # moves of `account.balance` stand for the actual position.
    def fork_loan(balance:, interest_rate: 3.5, term_months: 360, start_date: Date.current, rate_type: "fixed")
      account = Account.create!(
        family: @family, name: "Test Loan #{SecureRandom.hex(4)}", balance: balance, currency: "USD",
        accountable: Loan.create!(subtype: "mortgage", interest_rate: interest_rate, term_months: term_months,
                                  rate_type: rate_type, start_date: start_date)
      )
      account.entries.create!(name: "Starting balance", amount: balance, currency: "USD", date: start_date,
                              entryable: Valuation.new(kind: "opening_anchor"))
      account.loan
    end

    # Term ended a year ago, and $250,000 is still outstanding.
    def matured_loan_still_carrying_a_balance
      @family.accounts.create!(
        name: "Matured Loan", balance: 250_000.00, currency: "USD",
        accountable: Loan.new(rate_type: "variable", interest_rate: 6.0, term_months: 12,
                              initial_balance: 400_000, start_date: Date.current - 24.months)
      ).loan.reload
    end

    # Contracted at 1%, then a rise to 12% already in effect: the contracted
    # repayment no longer covers a single period's interest.
    def loan_whose_contracted_payment_no_longer_covers_interest
      loan = @family.accounts.create!(
        name: "Under-serviced Loan", balance: 400_762.12, currency: "USD",
        accountable: Loan.new(rate_type: "variable", interest_rate: 1.0, term_months: 360,
                              initial_balance: 400_762.12, start_date: Date.current - 83.months)
      ).loan

      loan.add_variable_rate_change(Date.current - 1.month, 12.0)
      loan.reload.add_variable_rate_change(Date.current + 6.months, 13.0)
      loan.reload
    end
end
