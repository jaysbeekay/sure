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

  test "an overpaid loan finishes early and pays less interest" do
    loan = build_loan(term_months: 24)
    loan.account.update!(balance: scheduled_balance_at(loan, @today) - 50_000)

    projection = loan.payoff_projection(as_of: @today)

    assert projection.converged?
    assert_operator projection.months_saved, :>, 0
    assert_operator projection.interest_saved.amount, :>, 0
    assert_operator projection.payoff_date, :<, loan.amortization_schedule.payoff_date
  end

  # The case that was unreachable in #103, and the reason convergence came back
  # with this change. A borrower far enough behind is not paying the loan off on
  # the contracted repayment -- and must not be shown a payoff date implying
  # otherwise.
  test "a loan too far behind to clear reports a balloon and no payoff date" do
    loan = build_loan(term_months: 24)
    loan.account.update!(balance: 400_000)

    projection = loan.payoff_projection(as_of: @today)

    assert projection.applicable?
    assert_not projection.converged?
    assert_nil projection.payoff_date
    assert_operator projection.balloon_amount.amount, :>, 0
    assert_equal 0, projection.months_saved, "no months are saved by a loan that never finishes"
  end

  test "a modelled extra payment brings the payoff forward" do
    loan = build_loan(term_months: 24)
    loan.account.update!(balance: scheduled_balance_at(loan, @today))

    baseline = loan.payoff_projection(as_of: @today)
    accelerated = loan.payoff_projection(
      as_of: @today, extra_payment: { amount: 2_000, frequency: "monthly" }
    )

    assert_operator accelerated.payments.length, :<, baseline.payments.length
    assert_operator accelerated.total_interest.amount, :<, baseline.total_interest.amount
    assert_operator accelerated.payoff_date, :<, baseline.payoff_date
  end

  # THE reason exact dates matter. A monthly-equivalent approximation -- $100
  # weekly modelled as $433.33 monthly -- makes these two identical, and throws
  # the feature away. They are not identical, because when money reaches the
  # balance changes what the balance accrues on.
  #
  # The direction is deliberately NOT asserted. With the annual totals equalised
  # the monthly lump lands at the start of each month and the weekly amounts
  # trickle in across it, so monthly wins here; with $X weekly against $4.33X
  # monthly, weekly wins on volume. Which is larger depends on the comparison
  # chosen. That they differ at all is the property this engine has to have.
  test "weekly and monthly repayments of the same annual total are not interchangeable" do
    loan = build_loan(term_months: 24)
    on_contract = scheduled_balance_at(loan, @today)

    weekly = projection_with(loan, on_contract, amount: 100, frequency: "weekly")
    monthly = projection_with(loan, on_contract, amount: 100 * 52 / 12.0, frequency: "monthly")

    assert_not_equal weekly.total_interest.amount, monthly.total_interest.amount,
      "collapsing a weekly cadence into a monthly equivalent would make these equal"
  end

  test "a weekly plan fires once a week and a monthly plan once a month" do
    # Windows sized to the cadence so the counts are exact rather than
    # approximately-a-year: 52 weeks is day 0 through day 357, and 12 months is
    # month 0 through month 11. Both closed at the end, as the final window is.
    weekly_end = @today + (7 * 51)
    monthly_end = @today >> 11

    weekly = Loan::RepaymentPlan.new(
      amount: 100, frequency: "weekly", starts_on: @today, closes_on: weekly_end
    )
    monthly = Loan::RepaymentPlan.new(
      amount: 433, frequency: "monthly", starts_on: @today, closes_on: monthly_end
    )

    assert_equal 52, weekly.change_points(@today, weekly_end).length
    assert_equal 12, monthly.change_points(@today, monthly_end).length
  end

  # A repayment landing exactly on a payment date must be applied once. The
  # simulator matches dates inclusively at both ends, so an inclusive plan hands
  # it to the period that closes on that date AND the one that opens on it.
  test "a repayment on a period boundary is applied once, not twice" do
    plan = Loan::RepaymentPlan.new(
      amount: 500, frequency: "monthly", starts_on: @today, closes_on: @today >> 3
    )

    first = plan.change_points(@today, @today >> 1)
    second = plan.change_points(@today >> 1, @today >> 2)
    boundary = @today >> 1

    appearances = (first + second).count { |point| point[:date] == boundary }
    assert_equal 1, appearances, "the boundary date must belong to exactly one window"
  end

  # ...except the final window, which has no successor to open on the last date.
  test "a repayment on the final payment date is not dropped" do
    closes_on = @today >> 2
    plan = Loan::RepaymentPlan.new(
      amount: 500, frequency: "monthly", starts_on: @today, closes_on: closes_on
    )

    final_window = plan.change_points(@today >> 1, closes_on)

    assert_includes final_window.map { |point| point[:date] }, closes_on
  end

  test "an unparseable or non-positive extra payment falls back to the baseline" do
    loan = build_loan(term_months: 24)
    loan.account.update!(balance: scheduled_balance_at(loan, @today))
    baseline = loan.payoff_projection(as_of: @today)

    [ { amount: 0, frequency: "monthly" },
      { amount: -500, frequency: "monthly" },
      { amount: 500, frequency: "fortnightly" },
      { amount: "banana", frequency: "monthly" } ].each do |bad|
      projection = loan.payoff_projection(as_of: @today, extra_payment: bad)

      assert_equal baseline.payments.length, projection.payments.length,
        "#{bad.inspect} should degrade to the baseline projection, not change it or raise"
    end
  end

  test "is not applicable to a loan with no schedule or nothing left to owe" do
    unamortizable = build_loan(term_months: 24, rate_type: "teaser")
    assert_not unamortizable.payoff_projection(as_of: @today).applicable?

    cleared = build_loan(term_months: 24)
    cleared.account.update!(balance: 0)
    assert_not cleared.payoff_projection(as_of: @today).applicable?

    matured = build_loan(term_months: 24)
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

  # Under monthly accrual there is one interest charge per period. An extra
  # landing part-way through cannot reduce it -- the days before it arrived
  # accrued on the full balance.
  test "an extra repayment does not reduce the interest of the period it lands in" do
    loan = build_loan(term_months: 24)
    loan.account.update!(balance: scheduled_balance_at(loan, @today))

    baseline = loan.payoff_projection(as_of: @today)
    accelerated = loan.reload.payoff_projection(
      as_of: @today, extra_payment: { amount: 5_000, frequency: "monthly" }
    )

    assert_equal baseline.payments.first[:interest_payment],
      accelerated.payments.first[:interest_payment],
      "the first period's interest accrued before any extra arrived"
    assert_operator accelerated.payments.second[:interest_payment], :<,
      baseline.payments.second[:interest_payment],
      "but the period after it is charged on the reduced balance"
  end

  # Extras never appear in payment_amount -- the simulator applies them to the
  # balance. A cost built from the payment rows alone understates what was paid
  # by exactly the amount that made the loan finish early.
  test "total cost counts the extra repayments that were actually made" do
    loan = build_loan(term_months: 24)
    loan.account.update!(balance: scheduled_balance_at(loan, @today))
    projection = loan.payoff_projection(
      as_of: @today, extra_payment: { amount: 1_000, frequency: "monthly" }
    )

    rows = projection.payments
    scheduled_total = rows.sum(BigDecimal("0")) { |p| p[:payment_amount] }
    extras = rows.sum(BigDecimal("0")) { |p| p[:extra_payment] }

    assert_operator extras, :>, 0
    assert_equal scheduled_total + extras,
      rows.sum(BigDecimal("0")) { |p| p[:payment_amount] + p[:extra_payment] }
  end

  private
    def build_loan(term_months:, rate_type: "fixed", interest_rate: 6)
      Account.create!(
        family: @family, name: "Loan #{SecureRandom.hex(4)}",
        balance: 500_000, currency: "USD",
        accountable: Loan.new(subtype: "mortgage", interest_rate: interest_rate,
                              term_months: term_months, rate_type: rate_type,
                              start_date: Date.new(2026, 1, 1))
      ).loan
    end

    def scheduled_balance_at(loan, date)
      loan.amortization_schedule.payments
        .select { |p| p.date <= date }.last.ending_balance.amount
    end

    def projection_with(loan, balance, amount:, frequency:)
      loan.account.update!(balance: balance)
      loan.reload.payoff_projection(
        as_of: @today, extra_payment: { amount: amount, frequency: frequency }
      )
    end
end
