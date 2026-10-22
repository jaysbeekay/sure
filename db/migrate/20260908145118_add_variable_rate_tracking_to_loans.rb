# Upstream's migration (we-promise/sure#3473). On a fork database the two
# columns were already added by the fork's own
# 20260831160656_create_loan_amortizations_with_variable_rate_tracking, whose
# file is gone but whose version is still recorded, so here they are guarded
# with `if_not_exists`. Upstream's copy has no guards and a reversible
# `change`; the guards and the no-op `down` are the differences.
class AddVariableRateTrackingToLoans < ActiveRecord::Migration[8.1]
  def up
    # Effective date => annual percentage, e.g. {"2026-04-01" => "6.15"}.
    # A JSONB column rather than a table: a handful of rows per loan, always
    # read together when a schedule is built, never queried across loans.
    add_column :loans, :variable_rate_schedule, :jsonb, null: false, default: {}, if_not_exists: true

    # When the loan was drawn down. Optional -- origination otherwise comes
    # from the account's first valuation, which is where it came from before
    # this column existed and remains the answer for most loans.
    add_column :loans, :start_date, :date, if_not_exists: true
  end

  # Deliberately empty. On a fork database these columns predate this
  # migration, so reversing `add_column` here would drop every loan's rate
  # schedule and start date on a rollback past it (cubic, #396).
  def down
  end
end
