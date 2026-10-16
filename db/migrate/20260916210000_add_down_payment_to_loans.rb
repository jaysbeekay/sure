# What the borrower put in up front (upstream #3327).
#
# Guarded so it is safe to run against a database that already has the column:
# this migration reached the fork's history on an upstream sync branch before
# fork `main` dropped it (#184), so a database built from that branch can carry
# the column without this version recorded.
class AddDownPaymentToLoans < ActiveRecord::Migration[8.1]
  def change
    add_column :loans, :down_payment, :decimal, precision: 19, scale: 4, if_not_exists: true
    add_check_constraint :loans,
      "down_payment IS NULL OR down_payment >= 0",
      name: "chk_loans_down_payment_non_negative",
      if_not_exists: true
  end
end
