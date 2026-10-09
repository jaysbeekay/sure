require "test_helper"

# #188 on the fork: 30/360, upstream's flat 1/12, on the fork's daily engine.
#
# Every scheduled period is one month of 30 days, so a full period charges
# exactly balance x rate / 12 whatever its calendar length -- the figure
# upstream's monthly engine charges, row for row. A part-period (the payoff
# projection's first stub) counts 30E/360 days. A change part-way through a
# period splits that period's month by elapsed actual days.
class Loan::Thirty360Test < ActiveSupport::TestCase
  test "a full period charges a twelfth of the annual rate whatever its length" do
    {
      [ Date.new(2026, 1, 1), Date.new(2026, 2, 1) ] => "31 days",
      [ Date.new(2026, 2, 1), Date.new(2026, 3, 1) ] => "28 days",
      [ Date.new(2028, 2, 1), Date.new(2028, 3, 1) ] => "29 days, leap",
      [ Date.new(2026, 4, 1), Date.new(2026, 5, 1) ] => "30 days",
      [ Date.new(2026, 1, 31), Date.new(2026, 2, 28) ] => "month-end clamp"
    }.each do |(from, to), label|
      assert_equal BigDecimal("1500"), accrue(from, to), label
    end
  end

  # The same month on actual/365 differs, so the figure above is the
  # convention's doing.
  test "actual/365 charges the same months differently" do
    assert_equal BigDecimal("1380.82"),
      accrue(Date.new(2026, 2, 1), Date.new(2026, 3, 1), convention: :actual_365).round(2)
  end

  test "a change part-way through a period splits its month by elapsed days" do
    interest = accrue(
      Date.new(2026, 1, 1), Date.new(2026, 2, 1),
      change_points: [ { date: Date.new(2026, 1, 15), rate: "7" } ]
    )

    # 14/31 of a month at 6% and 17/31 at 7%.
    expected = BigDecimal("1500") * 14 / 31 + BigDecimal("1750") * 17 / 31
    assert_equal expected.round(10), interest.round(10)
    assert_equal BigDecimal("1637.10"), interest.round(2)
  end

  test "a part-period counts 30/360 days" do
    # 2026-01-10 to 2026-02-01 is 21 days on 30E/360: 20 left in January
    # (counted to day 30) and 1 in February.
    assert_equal BigDecimal("1050"), accrue(Date.new(2026, 1, 10), Date.new(2026, 2, 1))

    # A 31st counts as the 30th, so 20 to 31 January is 10 days, not 11.
    assert_equal BigDecimal("500"), accrue(Date.new(2026, 1, 20), Date.new(2026, 1, 31)).round(10)
  end

  test "a schedule on thirty_360 equals the flat-twelfth schedule row for row" do
    loan = loan_on("thirty_360")

    daily = loan.amortization_schedule.payments
    flat = loan.amortization_schedule.simulation(daily_accrual: false).payments

    assert_equal 360, daily.length
    assert_equal flat, daily
    assert_equal BigDecimal("1500.00"), daily.first[:interest_payment]
  end

  test "the same loan on actual/365 does not" do
    loan = loan_on("actual_365")

    assert_not_equal loan.amortization_schedule.simulation(daily_accrual: false).payments,
      loan.amortization_schedule.payments
  end

  test "a loan accepts thirty_360 and the database stores it" do
    loan = loan_on("thirty_360")

    assert_equal "thirty_360", loan.reload.day_count_convention
  end

  private

    def accrue(from, to, convention: :thirty_360, change_points: [])
      Loan::InterestAccrual.calculate(
        from_date: from, to_date: to, balance: "300000", annual_rate: "6",
        change_points: change_points, day_count_convention: convention
      )
    end

    def loan_on(convention)
      account = families(:dylan_family).accounts.create!(
        name: "30/360 loan", balance: 300_000, currency: "USD",
        accountable: Loan.new(
          rate_type: "fixed", interest_rate: 6, term_months: 360, initial_balance: 300_000,
          start_date: Date.new(2026, 1, 31), day_count_convention: convention
        )
      )
      account.entries.create!(
        name: "Opening", amount: 300_000, currency: "USD", date: Date.new(2026, 1, 31),
        entryable: Valuation.new(kind: "opening_anchor")
      )
      account.loan.reload
    end
end
