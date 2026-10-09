# Lets a loan accrue on actual/360 (#284). A check constraint cannot be
# widened in place, so it is replaced; `down` restores the three values.
class AllowActual360DayCountOnLoans < ActiveRecord::Migration[8.1]
  CONSTRAINT = "chk_loans_day_count_convention".freeze

  def up
    remove_check_constraint :loans, name: CONSTRAINT, if_exists: true
    add_check_constraint :loans,
      "day_count_convention IN ('actual_365', 'actual_actual', 'thirty_360', 'actual_360')",
      name: CONSTRAINT
  end

  def down
    remove_check_constraint :loans, name: CONSTRAINT, if_exists: true
    add_check_constraint :loans,
      "day_count_convention IN ('actual_365', 'actual_actual', 'thirty_360')",
      name: CONSTRAINT
  end
end
