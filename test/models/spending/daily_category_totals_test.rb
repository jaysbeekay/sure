require "test_helper"

# The sibling queries (Totals, DailyExpenseTotals) refuse a date range that is not a
# Range of date-like values; this one takes the same period, so it refuses the same.
class Spending::DailyCategoryTotalsTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
  end

  test "a period whose date range is not a Range is refused" do
    period = OpenStruct.new(date_range: "2024-03-01..2024-03-31")

    assert_raises(ArgumentError) { Spending::DailyCategoryTotals.new(@family, period: period) }
  end

  test "a range of things that are not dates is refused" do
    period = OpenStruct.new(date_range: (1..5))

    assert_raises(ArgumentError) { Spending::DailyCategoryTotals.new(@family, period: period) }
  end

  test "a real period is accepted" do
    period = Period.custom(start_date: Date.new(2024, 3, 1), end_date: Date.new(2024, 3, 31))

    assert_nothing_raised { Spending::DailyCategoryTotals.new(@family, period: period) }
  end
end
