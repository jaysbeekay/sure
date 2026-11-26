# frozen_string_literal: true

require "test_helper"
require Rails.root.join("db/migrate/20261124090000_ensure_enable_banking_pending_totals")

# A fork database recorded 20261118090000 for WidenHoldingLotUnitCost, so it
# skipped upstream's migration of the same version, which adds these columns.
#
# DDL is transactional in PostgreSQL, so each test's schema change rolls back
# with the test (see EnsureTradeRepublicSessionExpiresAtMigrationTest).
class EnsureEnableBankingPendingTotalsMigrationTest < ActiveSupport::TestCase
  COLUMNS = %i[pending_total anchor_pending_total].freeze

  teardown do
    EnableBankingAccount.reset_column_information
  end

  test "adds the columns where upstream's migration was skipped" do
    COLUMNS.each { |column| connection.remove_column :enable_banking_accounts, column }

    run_migration

    COLUMNS.each do |column|
      assert connection.column_exists?(:enable_banking_accounts, column, :decimal, precision: 19, scale: 4), column
    end
  end

  test "adds only the column that is missing" do
    connection.remove_column :enable_banking_accounts, :anchor_pending_total
    kept = column_definition(:pending_total)

    run_migration

    assert connection.column_exists?(:enable_banking_accounts, :anchor_pending_total, :decimal, precision: 19, scale: 4)
    assert_equal kept, column_definition(:pending_total)
  end

  test "does nothing where the columns are already there" do
    before = COLUMNS.map { |column| column_definition(column) }

    assert_nothing_raised { run_migration }

    assert_equal before, COLUMNS.map { |column| column_definition(column) }
  end

  private
    def column_definition(name)
      connection.columns(:enable_banking_accounts).find { |column| column.name == name.to_s }
        &.then { |column| [ column.sql_type, column.null, column.default ] }
    end

    def connection
      ActiveRecord::Base.connection
    end

    def run_migration
      ActiveRecord::Migration.suppress_messages { EnsureEnableBankingPendingTotals.new.up }
    end
end
