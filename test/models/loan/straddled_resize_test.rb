require "test_helper"

# #184 (comment 5738608741): the period a rate change resizes accrued, wholly
# or partly, at the OLD rate, but the fork sized its new repayment with the
# plain annuity, which assumes every remaining period -- that one included --
# accrues at the new rate. The payment then over- or under-covered that period
# and the error compounded into the final settlement: on a 300k, 360-month loan
# moving 4.8% -> 6.0% it put the last payment $662 below the level repayment,
# against +$424 for the same loan with no change.
#
# Upstream fixed this in AmortizationMath with `first_period_interest`; the
# fork shares that file but never passed it. Since #184's core swap the fork
# runs upstream's simulator, which passes it -- with the interest the period
# actually charged through the fork's daily hook.
class Loan::StraddledResizeTest < ActiveSupport::TestCase
  test "a resize on a payment-date change is sized from the interest that period charged" do
    loan = loan_with({ "2030-02-15" => "6.0" })
    rows = loan.amortization_rows
    resized = rows.find { |row| row[:payment_date] == Date.new(2030, 2, 15) }
    before = rows[rows.index(resized) - 1]

    assert_not_equal before[:payment_amount], resized[:payment_amount], "precondition: this is the resize"
    assert_equal expected_payment(resized, rows, loan), resized[:payment_amount]
  end

  test "a resize on a mid-period change is sized from the interest that period charged" do
    loan = loan_with({ "2030-02-01" => "6.0" })
    rows = loan.amortization_rows
    resized = rows.find { |row| row[:payment_date] == Date.new(2030, 2, 15) }

    assert_equal expected_payment(resized, rows, loan), resized[:payment_amount]
  end

  # The outcome. Sized on the interest the opening period actually charged,
  # the resized payment amortises what that period leaves over the remaining
  # periods exactly as a fresh loan would: same repayment, same final
  # settlement, give or take a cent or two of rounding. The settlement gap left
  # is only the daily-accrual drift the annuity cannot see after the change.
  # Before the fix the straddle added hundreds: -662.09, -293.84 and +344.87
  # for these three.
  test "after a resize the loan runs as a fresh loan on what the resized period leaves" do
    [ { "2030-02-15" => "6.0" }, { "2030-02-01" => "6.0" }, { "2030-02-01" => "3.6" } ].each do |schedule|
      loan = loan_with(schedule)
      rows = loan.amortization_rows
      resized = rows.find { |row| row[:payment_date] == Date.new(2030, 2, 15) }
      fresh = loan_with({}, rate: schedule.values.first, start: Date.new(2030, 2, 15),
                            principal: resized[:ending_balance], term: rows.length - rows.index(resized) - 1)

      assert_in_delta fresh.amortization_rows.first[:payment_amount], resized[:payment_amount],
        BigDecimal("0.02"), "#{schedule}: the resized repayment must be the fresh loan's"
      assert_in_delta settlement_gap(fresh), settlement_gap(loan), BigDecimal("2"),
        "#{schedule}: the change must not move the final settlement beyond the drift a fresh loan carries"
    end
  end

  # The sibling: the projection pays the schedule's own resize, so it carries
  # the straddle-aware figure rather than sizing one of its own. (The fork's
  # re-amortising projection, which sized its own and had the same straddle,
  # went with the core swap.)
  test "the projection pays the schedule's straddle-aware resize" do
    loan = loan_with({}, start: Date.current - 24.months)
    loan.update!(rate_type: "variable")
    change_on = Date.current + 3.months
    loan.add_variable_rate_change(change_on, 6.0)
    loan.reload

    schedule_rows = loan.amortization_rows
    rows = loan.payoff_projection.payments
    resized = rows.find { |row| row[:payment_date] >= change_on }
    before = rows[rows.index(resized) - 1]
    scheduled = schedule_rows.find { |row| row[:payment_date] == resized[:payment_date] }

    assert_not_equal before[:payment_amount], resized[:payment_amount], "precondition: this is the resize"
    assert_equal expected_payment(scheduled, schedule_rows, loan), resized[:payment_amount]
  end

  # The negative: the first segment is sized as before, so a loan with no
  # change keeps its schedule (the golden master pins it row for row).
  test "a loan with no change is sized with the plain annuity" do
    loan = loan_with({})
    first = loan.amortization_rows.first

    assert_equal Loan::AmortizationMath.level_payment(
      balance: BigDecimal("300000"), monthly_rate: monthly_rate("4.8"), remaining_payments: 360, currency_precision: 2
    ), first[:payment_amount]
  end

  private

    # An annual percentage as a monthly decimal rate, the conversion
    # Loan::Simulator makes.
    def monthly_rate(annual_percentage)
      (BigDecimal(annual_percentage.to_s) / BigDecimal("100")) / BigDecimal("12")
    end

    # The row's interest_rate is the rate its period OPENED on; the resize is
    # sized at the rate in force on its payment date.
    def expected_payment(resized, rows, loan)
      Loan::AmortizationMath.level_payment(
        balance: resized[:beginning_balance],
        monthly_rate: monthly_rate(loan.current_variable_rate(resized[:payment_date])),
        remaining_payments: rows.length - rows.index(resized),
        currency_precision: 2,
        first_period_interest: resized[:interest_payment]
      )
    end

    def settlement_gap(loan)
      rows = loan.amortization_rows
      rows.last[:payment_amount] - rows[-2][:payment_amount]
    end

    def loan_with(schedule, rate: "4.8", start: Date.new(2020, 1, 15), principal: 300_000, term: 360)
      account = families(:dylan_family).accounts.create!(
        name: "Straddle #{SecureRandom.hex(3)}", balance: principal, currency: "USD",
        accountable: Loan.new(
          rate_type: schedule.empty? ? "fixed" : "variable", interest_rate: rate, term_months: term,
          initial_balance: principal, start_date: start, variable_rate_schedule: schedule,
          day_count_convention: "actual_365"
        )
      )
      account.entries.create!(
        name: "Opening", amount: principal, currency: "USD", date: start,
        entryable: Valuation.new(kind: "opening_anchor")
      )
      account.loan.reload
    end
end
