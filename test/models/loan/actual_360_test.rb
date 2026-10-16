require "test_helper"

# #284: actual/360, the actual days in a period over a 360-day year, which US
# commercial and some consumer lenders charge.
class Loan::Actual360Test < ActiveSupport::TestCase
  test "actual/360 charges the period's days over 360" do
    interest = accrue(Date.new(2026, 1, 1), Date.new(2026, 2, 1), :actual_360)

    # 100,000 x 6% x 31 / 360
    assert_equal BigDecimal("516.67"), interest.round(2)
    assert_equal (BigDecimal("100000") * 6 / 100 * 31 / 360).round(10), interest.round(10)
  end

  # The fall-through this replaces: an unbranched basis was charged over 365.
  test "actual/360 is not actual/365" do
    assert_not_equal accrue(Date.new(2026, 1, 1), Date.new(2026, 2, 1), :actual_365).round(2),
      accrue(Date.new(2026, 1, 1), Date.new(2026, 2, 1), :actual_360).round(2)
  end

  test "a leap February differs on each actual basis" do
    from = Date.new(2028, 2, 1)
    to = Date.new(2028, 3, 1)

    figures = %i[actual_360 actual_365 actual_actual].index_with { |basis| accrue(from, to, basis).round(2) }

    assert_equal BigDecimal("483.33"), figures[:actual_360], "29 / 360"
    assert_equal BigDecimal("476.71"), figures[:actual_365], "29 / 365"
    assert_equal BigDecimal("475.41"), figures[:actual_actual], "29 / 366"
  end

  test "a basis with no denominator raises rather than defaulting" do
    error = assert_raises(ArgumentError) do
      Loan::InterestAccrual.new.send(:day_count_denominator, Date.new(2026, 1, 1), :actual_366)
    end

    assert_match "actual_366", error.message
  end

  test "an unsupported basis passed to the accrual still raises" do
    assert_raises(ArgumentError) { accrue(Date.new(2026, 1, 1), Date.new(2026, 2, 1), :actual_366) }
  end

  test "a loan saves actual_360 and the database refuses an unknown basis" do
    loan = accounts(:loan).loan
    loan.update!(day_count_convention: "actual_360")
    assert_equal "actual_360", loan.reload.day_count_convention

    assert_raises(ActiveRecord::StatementInvalid) do
      loan.update_column(:day_count_convention, "actual_366")
    end
  end

  private

    def accrue(from, to, basis)
      Loan::InterestAccrual.calculate(
        from_date: from, to_date: to, balance: "100000", annual_rate: "6", day_count_convention: basis
      )
    end
end
