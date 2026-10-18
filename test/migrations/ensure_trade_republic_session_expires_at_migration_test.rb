# frozen_string_literal: true

require "test_helper"
require Rails.root.join("db/migrate/20261018090000_ensure_trade_republic_session_expires_at")

# A fork database recorded 20261015090000 for the rule position migration, so
# it skipped upstream's migration of the same version, which adds this column.
class EnsureTradeRepublicSessionExpiresAtMigrationTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  teardown do
    connection = ActiveRecord::Base.connection
    connection.add_column :trade_republic_items, :session_expires_at, :datetime unless connection.column_exists?(:trade_republic_items, :session_expires_at)
    TradeRepublicItem.reset_column_information
  end

  test "adds the column where upstream's migration was skipped" do
    ActiveRecord::Base.connection.remove_column :trade_republic_items, :session_expires_at

    run_migration

    assert ActiveRecord::Base.connection.column_exists?(:trade_republic_items, :session_expires_at, :datetime)
  end

  test "does nothing where the column is already there" do
    assert ActiveRecord::Base.connection.column_exists?(:trade_republic_items, :session_expires_at)

    assert_nothing_raised { run_migration }
  end

  private
    def run_migration
      ActiveRecord::Migration.suppress_messages { EnsureTradeRepublicSessionExpiresAt.new.up }
    end
end
