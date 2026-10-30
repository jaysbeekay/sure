# frozen_string_literal: true

require "test_helper"
require Rails.root.join("db/migrate/20261018090000_ensure_trade_republic_session_expires_at")

# A fork database recorded 20261015090000 for the rule position migration, so
# it skipped upstream's migration of the same version, which adds this column.
#
# DDL is transactional in PostgreSQL, so each test's schema change rolls back
# with the test. Committing it instead re-adds the column at the end of the
# table, which changes the row type under every other pooled connection's
# prepared `SELECT "trade_republic_items".*`, and the transactional tests that
# run on those connections afterwards fail with "cached plan must not change
# result type".
class EnsureTradeRepublicSessionExpiresAtMigrationTest < ActiveSupport::TestCase
  teardown do
    TradeRepublicItem.reset_column_information
  end

  test "adds the column where upstream's migration was skipped" do
    connection.remove_column :trade_republic_items, :session_expires_at

    run_migration

    assert connection.column_exists?(:trade_republic_items, :session_expires_at, :datetime)
  end

  test "does nothing where the column is already there" do
    assert connection.column_exists?(:trade_republic_items, :session_expires_at)

    assert_nothing_raised { run_migration }
  end

  private
    def connection
      ActiveRecord::Base.connection
    end

    def run_migration
      ActiveRecord::Migration.suppress_messages { EnsureTradeRepublicSessionExpiresAt.new.up }
    end
end
