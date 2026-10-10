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

  # The code before this migration cannot read 30/360, so a loan on it goes
  # back to actual/365, the basis every loan had before #188. Without this the
  # narrower constraint rejects those rows and the rollback fails (cubic,
  # #397). The loan's schedule signature changes with its basis, so it is
  # rebuilt on next view.
  def down
    say_with_time "Moving 30/360 loans back to actual/365" do
      execute "UPDATE loans SET day_count_convention = 'actual_365' WHERE day_count_convention = 'thirty_360'"
    end
    remove_check_constraint :loans, name: CONSTRAINT, if_exists: true
    add_check_constraint :loans,
      "day_count_convention IN ('actual_365', 'actual_actual')",
      name: CONSTRAINT
  end
end
