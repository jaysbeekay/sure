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

  # The code before this migration cannot read actual/360, and the narrower
  # constraint rejects a loan still on it. Moving such a loan to another basis
  # would change its interest and lose the basis its contract names, and a
  # later re-upgrade could not tell which loans had it. So the rollback refuses
  # while any loan is on actual/360, before changing anything; whoever rolls
  # back decides each loan's basis first.
  def down
    affected = select_value("SELECT COUNT(*) FROM loans WHERE day_count_convention = 'actual_360'").to_i
    if affected.positive?
      raise ActiveRecord::IrreversibleMigration,
        "#{affected} #{affected == 1 ? "loan accrues" : "loans accrue"} on actual/360, which the code before this " \
        "migration cannot read. Rolling back would have to change their day-count basis, and with it their interest. " \
        "Set each one's basis yourself, then roll back again."
    end

    remove_check_constraint :loans, name: CONSTRAINT, if_exists: true
    add_check_constraint :loans,
      "day_count_convention IN ('actual_365', 'actual_actual', 'thirty_360')",
      name: CONSTRAINT
  end
end
