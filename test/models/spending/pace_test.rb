require "test_helper"

class Spending::PaceTest < ActiveSupport::TestCase
  # June 2026 has 30 days, so the elapsed fraction on day N is N/30 and every
  # boundary below is an exact decimal, not a float that merely rounds well.
  START = Date.new(2026, 6, 1)
  FINISH = Date.new(2026, 6, 30)

  # The budget supplies the period and the amount only; what has been spent is
  # passed in, because it must be the spend through the reference date, not
  # the budget's whole-month actual_spending.
  def budget(budgeted: 1000)
    OpenStruct.new(start_date: START, end_date: FINISH, budgeted_spending: budgeted&.to_d)
  end

  def pace(spent:, day:, budgeted: 1000)
    Spending::Pace.for(budget(budgeted: budgeted), on: Date.new(2026, 6, day), spent: spent.to_d)
  end

  # The approaching threshold is a 5% tolerance on the straight-line pace:
  # on day 15 (half the month) a 1,000 budget allows 500 of spend, so 525 is
  # exactly 1.05x pace. At the line is on track; a cent past it is approaching.
  test "exactly 5 percent ahead of pace is still on track" do
    assert_equal :on_track, pace(spent: "525.00", day: 15).status
  end

  test "a cent past 5 percent ahead of pace is approaching" do
    assert_equal :approaching, pace(spent: "525.01", day: 15).status
  end

  test "spending below the straight-line pace is on track" do
    assert_equal :on_track, pace(spent: "100", day: 15).status
  end

  # The same 300 spent is on pace on day 9 (9/30 = 30%) and ahead of it a day
  # earlier (8/30 = 26.7%), so the elapsed fraction, not just the spend, moves
  # the status.
  test "the same spend flips from on track to approaching as the month is less elapsed" do
    assert_equal :on_track, pace(spent: "300", day: 9).status
    assert_equal :approaching, pace(spent: "300", day: 8).status
  end

  # Over means the whole budget is spent, not that the pace is high.
  test "spending exactly the full budget on the last day is on track, not over" do
    assert_equal :on_track, pace(spent: "1000", day: 30).status
  end

  test "a cent over the full budget is over, even on the last day" do
    assert_equal :over, pace(spent: "1000.01", day: 30).status
  end

  test "spending the full budget early is approaching until it is exceeded" do
    assert_equal :approaching, pace(spent: "1000", day: 15).status
    assert_equal :over, pace(spent: "1000.01", day: 15).status
  end

  test "exposes the fractions and the projection the page shows" do
    result = pace(spent: "400", day: 10)

    assert_equal 10, result.elapsed_days
    assert_equal 30, result.total_days
    assert_equal Rational(1, 3), result.elapsed_fraction
    assert_equal Rational(2, 5), result.spent_fraction
    assert_equal 33, result.elapsed_percent
    assert_equal 40, result.spent_percent
    assert_equal 1200.to_d, result.projected_spend
    assert_equal 1000.to_d, result.budgeted
    assert_equal 400.to_d, result.spent
  end

  test "no budget means no pace" do
    assert_nil Spending::Pace.for(nil, on: Date.new(2026, 6, 15), spent: 10.to_d)
  end

  test "a budget that has not been set up means no pace" do
    assert_nil pace(spent: "400", day: 15, budgeted: nil)
  end

  test "a zero budget means no pace and does not divide by zero" do
    assert_nil pace(spent: "400", day: 15, budgeted: 0)
  end

  test "a date after the period counts the whole period as elapsed" do
    result = Spending::Pace.for(budget, on: Date.new(2026, 7, 20), spent: 900.to_d)

    assert_equal 30, result.elapsed_days
    assert_equal :on_track, result.status
  end

  test "a date before the period counts as the first day rather than raising" do
    result = Spending::Pace.for(budget, on: Date.new(2026, 5, 20), spent: 10.to_d)

    assert_equal 1, result.elapsed_days
  end
end
