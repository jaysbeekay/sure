require "test_helper"

# #189's headline figure, pinned on the engine and on the path production runs.
#
# 300,000 at 6%, moving to 7% on the 15th of a 31-day month, actual/365:
#   14 days @ 6% = 300000 * 0.06 * 14 / 365 =   690.4110
#   17 days @ 7% = 300000 * 0.07 * 17 / 365 =   978.0822
#                                            = 1,668.4932 -> 1,668.49
# A whole period at the opening 6% is 1,500.00 on a flat 1/12, and at the new 7%
# 1,750.00. Upstream's monthly engine charges the 1,500.00; the fork charges the
# split through the simulator's interest hook (Loan::DailyInterest, #184).
class Loan::MidPeriodRateChangeTest < ActiveSupport::TestCase
  test "the engine charges a mid-period change from its effective date" do
    change = ->(_from, _to) { [ { date: Date.new(2026, 1, 15), rate: BigDecimal("7") } ] }
    run = ->(interest_for) {
      Loan::Simulator.new(
        starting_balance: BigDecimal("300000"),
        accrual_start_date: Date.new(2026, 1, 1),
        payment_schedule: [ Date.new(2026, 2, 1) ],
        accrual_rate_for: ->(date) { date < Date.new(2026, 1, 15) ? BigDecimal("6") : BigDecimal("7") },
        payment_strategy: :hold,
        payment_amount: BigDecimal("300000"),
        currency_precision: 2,
        interest_for: interest_for
      ).run.payments.first[:interest_payment]
    }

    assert_equal BigDecimal("1500.00"), run.call(nil), "upstream's monthly charge: the opening rate throughout"
    assert_equal BigDecimal("1668.49"),
      run.call(Loan::DailyInterest.new(day_count_convention: :actual_365, rate_changes: change))
  end

  test "a variable loan's schedule charges the split figure for that period" do
    loan = variable_loan(changes: { "2026-01-15" => "7" })

    first = loan.amortization_schedule.payments.first

    assert_equal Date.new(2026, 2, 1), first.date
    assert_equal BigDecimal("1668.49"), first.interest.amount
  end

  # The negative: with no change the same period is 31 days at 6%, so the split
  # above is the change's doing and not the fixture's.
  test "without the change the period is charged at the opening rate throughout" do
    loan = variable_loan(changes: {})

    assert_equal BigDecimal("1528.77"), loan.amortization_schedule.payments.first.interest.amount,
      "300000 * 0.06 * 31 / 365"
  end

  private

    def variable_loan(changes:)
      account = families(:dylan_family).accounts.create!(
        name: "Mid-period change loan", balance: 300_000, currency: "USD",
        accountable: Loan.new(
          rate_type: "variable", interest_rate: 6, term_months: 360, initial_balance: 300_000,
          start_date: Date.new(2026, 1, 1), day_count_convention: "actual_365",
          variable_rate_schedule: changes
        )
      )
      account.entries.create!(
        name: "Opening", amount: 300_000, currency: "USD", date: Date.new(2026, 1, 1),
        entryable: Valuation.new(kind: "opening_anchor")
      )
      account.loan.reload
    end
end
