# frozen_string_literal: true

require "test_helper"
require Rails.root.join("db/migrate/20260908145118_add_variable_rate_tracking_to_loans")

# On a fork database the two columns predate this migration, so a rollback
# past it must not take them, or every loan's rate schedule and start date go
# with it. DDL is transactional in PostgreSQL, so the test's rollback puts the
# schema back either way.
class AddVariableRateTrackingToLoansMigrationTest < ActiveSupport::TestCase
  teardown do
    ActiveRecord::Base.connection.schema_cache.clear!
    Loan.reset_column_information
  end

  test "down keeps the columns and every loan's values in them" do
    loan = loans(:one)
    loan.update_columns(variable_rate_schedule: { "2026-01-15" => "5.2" }, start_date: Date.new(2020, 1, 1))

    quietly { AddVariableRateTrackingToLoans.new.down }

    connection = ActiveRecord::Base.connection
    assert connection.column_exists?(:loans, :variable_rate_schedule)
    assert connection.column_exists?(:loans, :start_date)
    Loan.reset_column_information
    loan.reload
    assert_equal({ "2026-01-15" => "5.2" }, loan.variable_rate_schedule)
    assert_equal Date.new(2020, 1, 1), loan.start_date
  end

  test "up on a database that already has the columns changes nothing" do
    loan = loans(:one)
    loan.update_columns(variable_rate_schedule: { "2026-01-15" => "5.2" })

    quietly { AddVariableRateTrackingToLoans.new.up }

    assert_equal({ "2026-01-15" => "5.2" }, loan.reload.variable_rate_schedule)
  end
  private
    def quietly(&block)
      capture_io(&block)
    end
end
