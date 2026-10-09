# Renamed from AddDayCountConventionToLoans (#184, phase 1), ahead of upstream
# we-promise/sure#3639, whose 20260918210000 declares the same class name and
# would otherwise stop `db:migrate` with DuplicateMigrationNameError on the
# first sync after it merges. Rails records migrations by version, so a
# database that ran this under the old name does not run it again.
class AddForkDayCountConventionToLoans < ActiveRecord::Migration[7.2]
  def change
    add_column :loans, :day_count_convention, :string, null: false, default: "actual_365"

    add_check_constraint :loans,
      "day_count_convention IN ('actual_365', 'actual_actual')",
      name: "chk_loans_day_count_convention"
  end
end
