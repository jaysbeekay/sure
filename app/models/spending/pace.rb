# Where a budget stands against the clock: how much of the budget is spent
# against how much of its period has elapsed.
#
# The reference date is always passed in. Nothing here reads the clock, so a
# page showing several date-sensitive figures can capture one date, and a test
# can pin it.
#
# Status, from the straight-line pace (spending that would land exactly on
# budget at the end of the period):
#
#   over        spent is more than the whole budget
#   approaching not over, but spent is more than APPROACHING_TOLERANCE times
#               the straight-line pace for the elapsed days
#   on_track    otherwise
#
# Both comparisons are exact (BigDecimal cross-multiplication, no float
# division), so a boundary is a boundary: exactly 1.05x pace is on track, and
# exactly the whole budget is not over.
class Spending::Pace
  STATUSES = %i[on_track approaching over].freeze

  # 5% ahead of the straight-line pace, as a fraction. Held as a Rational so
  # `spent * total_days > budgeted * elapsed_days * tolerance` stays exact.
  APPROACHING_TOLERANCE = Rational(105, 100)

  attr_reader :spent, :budgeted, :elapsed_days, :total_days

  # nil when there is nothing to measure against: no budget, one that has not
  # been set up (nil amount) or a zero amount. A pace is a ratio to the budget,
  # so without a positive one it has no meaning.
  #
  # `spent` is required and is the spend through `on`. It is deliberately not
  # read from the budget: Budget#actual_spending covers the whole month, which
  # includes anything dated after `on`, and a pace is spend measured against the
  # days that have actually elapsed.
  def self.for(budget, on:, spent:)
    return nil unless budget && budget.budgeted_spending.to_d.positive?

    new(
      spent: spent.to_d,
      budgeted: budget.budgeted_spending.to_d,
      start_date: budget.start_date,
      end_date: budget.end_date,
      on: on
    )
  end

  # `on` outside the period is clamped to it: after the period every day has
  # elapsed, and before it the first day is treated as elapsed so the fractions
  # never divide by zero.
  def initialize(spent:, budgeted:, start_date:, end_date:, on:)
    @spent = spent
    @budgeted = budgeted
    @total_days = (end_date - start_date).to_i + 1
    @elapsed_days = ((on - start_date).to_i + 1).clamp(1, @total_days)
  end

  def status
    return :over if spent > budgeted
    return :approaching if spent * total_days > budgeted * elapsed_days * APPROACHING_TOLERANCE

    :on_track
  end

  STATUSES.each do |name|
    define_method(:"#{name}?") { status == name }
  end

  def elapsed_fraction
    Rational(elapsed_days, total_days)
  end

  def spent_fraction
    spent.to_r / budgeted.to_r
  end

  # Whole percentages (rounded down) for display, so every surface that quotes
  # them -- the page and the insight facts -- quotes the same figure.
  def elapsed_percent
    (elapsed_fraction * 100).floor
  end

  def spent_percent
    (spent_fraction * 100).floor
  end

  # What the period ends at if the rest of it is spent at the rate so far.
  def projected_spend
    spent * total_days / elapsed_days
  end

  def days_remaining
    total_days - elapsed_days
  end
end
