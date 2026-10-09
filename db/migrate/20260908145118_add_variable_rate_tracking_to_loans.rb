# Upstream's migration (we-promise/sure#3473), admitted so weekly syncs stop
# having to delete it (#184, phase 1). The fork's own
# 20260831160656_create_loan_amortizations_with_variable_rate_tracking already
# adds both columns, so here they are guarded with `if_not_exists`: on a fork
# database this runs and changes nothing. Upstream's copy has no guards; the
# guards are the only difference.
class AddVariableRateTrackingToLoans < ActiveRecord::Migration[8.1]
  def change
    # Effective date => annual percentage, e.g. {"2026-04-01" => "6.15"}.
    # A JSONB column rather than a table: a handful of rows per loan, always
    # read together when a schedule is built, never queried across loans.
    add_column :loans, :variable_rate_schedule, :jsonb, null: false, default: {}, if_not_exists: true

    # When the loan was drawn down. Optional -- origination otherwise comes
    # from the account's first valuation, which is where it came from before
    # this column existed and remains the answer for most loans.
    add_column :loans, :start_date, :date, if_not_exists: true
  end
end
