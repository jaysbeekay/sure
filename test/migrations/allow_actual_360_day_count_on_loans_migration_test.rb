# frozen_string_literal: true

require "test_helper"
require Rails.root.join("db/migrate/20261009130000_allow_actual_360_day_count_on_loans")

# `down` rewrites data before it narrows the constraint: the code before this
# migration cannot read actual/360, so those loans move to actual/365. Without
# the rewrite the narrower constraint rejects them and the rollback fails. The
# schema change rolls back with the test's transaction.
class AllowActual360DayCountOnLoansMigrationTest < ActiveSupport::TestCase
  test "down moves actual/360 loans to actual/365 and restores the three-value constraint" do
    loan = accounts(:loan).loan
    loan.update!(day_count_convention: "actual_360")
    others = Loan.where.not(id: loan.id).pluck(:id, :day_count_convention).to_h

    ActiveRecord::Migration.suppress_messages { AllowActual360DayCountOnLoans.new.down }

    assert_equal "actual_365", loan.reload.day_count_convention
    assert_equal others, Loan.where.not(id: loan.id).pluck(:id, :day_count_convention).to_h,
      "only actual/360 loans move"
    assert_raises(ActiveRecord::StatementInvalid) { loan.update_column(:day_count_convention, "actual_360") }
  end
end
