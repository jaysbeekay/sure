# frozen_string_literal: true

# How a loan's interest is measured against a year.
#
# The default is `thirty_360` because it IS what the engine already charges:
# 30/360 reduces to a flat 1/12 exactly, so every existing loan keeps the
# schedule it had, row for row. `actual/actual` would NOT have done -- it
# charges 31/365 in January and 28/365 in February, and only reaches 1/12 when
# a whole calendar year is summed -- so choosing it as the default would have
# silently restated every schedule in the product.
#
# A plain string with a check constraint, matching `securities.kind`
# (`chk_securities_kind`): adding a convention later is a constraint swap, not
# a type change.
class AddDayCountConventionToLoans < ActiveRecord::Migration[8.1]
  CONVENTIONS = %w[thirty_360 actual_365 actual_actual].freeze
  CONSTRAINT = "chk_loans_day_count_convention"

  # This fork's 20260907000000 already added the column, with its own default
  # and check, and its loan engine reads those. So on the fork this only adds
  # what is missing and rollback leaves the fork's column alone. Once fork #478
  # converges the loan code, its migration moves the column to upstream's shape.
  def up
    return if column_exists?(:loans, :day_count_convention)

    add_column :loans, :day_count_convention, :string,
      null: false, default: "thirty_360"

    add_check_constraint :loans,
      "day_count_convention IN (#{CONVENTIONS.map { |v| "'#{v}'" }.join(', ')})",
      name: CONSTRAINT
  end

  def down; end
end
