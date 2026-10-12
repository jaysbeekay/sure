# frozen_string_literal: true

require "test_helper"
require Rails.root.join("db/migrate/20261009120000_allow_thirty_360_day_count_on_loans")

# The code before this migration cannot read 30/360, so `down` cannot keep a
# loan on it. Moving the loan to another basis would change its interest and
# lose the basis its contract names, so `down` refuses while any loan is on
# 30/360 and changes nothing. The schema change rolls back with the test's
# transaction.
class AllowThirty360DayCountOnLoansMigrationTest < ActiveSupport::TestCase
  test "down refuses while a loan accrues on 30/360 and leaves every loan's basis as it was" do
    Loan.update_all(day_count_convention: "actual_365")
    loan = accounts(:loan).loan
    loan.update!(day_count_convention: "thirty_360")
    before = Loan.pluck(:id, :day_count_convention).to_h

    error = assert_raises(ActiveRecord::IrreversibleMigration) do
      ActiveRecord::Migration.suppress_messages { AllowThirty360DayCountOnLoans.new.down }
    end

    assert_match "1 loan accrues on 30/360", error.message
    assert_equal before, Loan.pluck(:id, :day_count_convention).to_h
    assert_equal "thirty_360", loan.reload.day_count_convention
  end

  test "down restores the two-value constraint when no loan accrues on 30/360" do
    loan = accounts(:loan).loan
    Loan.where(day_count_convention: "thirty_360").update_all(day_count_convention: "actual_365")
    before = Loan.pluck(:id, :day_count_convention).to_h

    ActiveRecord::Migration.suppress_messages { AllowThirty360DayCountOnLoans.new.down }

    assert_equal before, Loan.pluck(:id, :day_count_convention).to_h
    assert_raises(ActiveRecord::StatementInvalid) { loan.update_column(:day_count_convention, "thirty_360") }
  end
end
