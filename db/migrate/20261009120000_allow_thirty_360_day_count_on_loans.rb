# Lets a loan accrue on 30/360 (#188), which the engine now supports. A check
# constraint cannot be widened in place, so it is replaced. The column default
# is unchanged here.
class AllowThirty360DayCountOnLoans < ActiveRecord::Migration[8.1]
  CONSTRAINT = "chk_loans_day_count_convention".freeze

  def up
    remove_check_constraint :loans, name: CONSTRAINT, if_exists: true
    add_check_constraint :loans,
      "day_count_convention IN ('actual_365', 'actual_actual', 'thirty_360')",
      name: CONSTRAINT
  end

  def down
    remove_check_constraint :loans, name: CONSTRAINT, if_exists: true
    add_check_constraint :loans,
      "day_count_convention IN ('actual_365', 'actual_actual')",
      name: CONSTRAINT
  end
end
