# New loans start on 30/360, upstream's basis (#184's 2026-09-30 decision:
# "Day-count default for new loans: thirty_360, as upstream. Existing fork
# rows keep actual_365."). Only the column default moves; no row is updated,
# so every existing loan keeps the basis -- and the schedule -- it has.
class DefaultNewLoansToThirty360 < ActiveRecord::Migration[8.1]
  def change
    change_column_default :loans, :day_count_convention, from: "actual_365", to: "thirty_360"
  end
end
