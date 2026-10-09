require "test_helper"

# #189's headline figure, pinned on the engine and on the path production runs.
#
# 300,000 at 6%, moving to 7% on the 15th of a 31-day month, actual/365:
#   14 days @ 6% = 300000 * 0.06 * 14 / 365 =   690.4110
#   17 days @ 7% = 300000 * 0.07 * 17 / 365 =   978.0822
#                                            = 1,668.4932 -> 1,668.49
# A whole period at the opening 6% is 1,500.00 on a flat 1/12, and at the new 7%
# 1,750.00. The fork already accrues daily (#25, SCHEDULE_DAILY_ACCRUAL); until
# now the mechanism was pinned by #25's 608.22 example but this figure was not.
class Loan::MidPeriodRateChangeTest < ActiveSupport::TestCase
  test "the engine charges a mid-period change from its effective date" do
    result = Loan::Simulator.new(
      starting_balance: BigDecimal("300000"),
      starting_balance_as_of: Date.new(2026, 1, 1),
      accrual_start_date: Date.new(2026, 1, 1),
      payment_schedule: [ Date.new(2026, 2, 1) ],
      accrual_rate_for: ->(_date) { BigDecimal("6") },
      accrual_rate_changes: ->(_from, _to) { [ { date: Date.new(2026, 1, 15), rate: BigDecimal("7") } ] },
      re_amortisation_events: ->(_from, _to) { [] },
      payment_strategy: :hold,
      payment_amount_for: ->(**_args) { BigDecimal("300000") },
      currency_precision: 2,
      daily_accrual: true,
      day_count_convention: :actual_365
    ).run

    assert_equal BigDecimal("1668.49"), result.payments.first[:interest_payment]
  end

  test "a variable loan's schedule charges the split figure for that period" do
    loan = variable_loan(changes: { "2026-01-15" => "7" })

    first = loan.amortization_schedule.payments.first

    assert_equal Date.new(2026, 2, 1), first[:payment_date]
    assert_equal BigDecimal("1668.49"), first[:interest_payment]
  end

  # The negative: with no change the same period is 31 days at 6%, so the split
  # above is the change's doing and not the fixture's.
  test "without the change the period is charged at the opening rate throughout" do
    loan = variable_loan(changes: {})

    assert_equal BigDecimal("1528.77"), loan.amortization_schedule.payments.first[:interest_payment],
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
