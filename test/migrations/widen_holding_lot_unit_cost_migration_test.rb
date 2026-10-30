# frozen_string_literal: true

require "test_helper"
require Rails.root.join("db/migrate/20261025090000_widen_holding_lot_unit_cost")

class WidenHoldingLotUnitCostMigrationTest < ActiveSupport::TestCase
  # Narrowing the columns again would overflow on a cost the old ones cannot
  # hold, so the rollback refuses rather than fail part-way.
  test "the rollback refuses while a lot's unit cost needs the wider columns" do
    HoldingLot.insert_all([ { account_id: account.id, security_id: security.id, qty: 1, unit_cost: BigDecimal("17500000000"), currency: "VND" } ])

    assert_raises(ActiveRecord::IrreversibleMigration) { migrate(:down) }
  end

  test "the rollback refuses while a disposal's unit cost needs the wider columns" do
    sale = account.entries.create!(name: "Sale", date: Date.current, amount: 0, currency: "VND", entryable: Trade.new(security: security, qty: -1, price: 1, currency: "VND"))
    HoldingLotDisposal.insert_all([ { account_id: account.id, sale_entry_id: sale.id, qty: 1, unit_cost: BigDecimal("17500000000"), currency: "VND" } ])

    assert_raises(ActiveRecord::IrreversibleMigration) { migrate(:down) }
  end

  private

    def account
      @account ||= families(:empty).accounts.create!(name: "Wide", balance: 0, currency: "VND", accountable: Investment.new)
    end

    def security
      @security ||= Security.create!(ticker: "WIDE", name: "Wide")
    end

    def migrate(direction)
      ActiveRecord::Migration.suppress_messages { WidenHoldingLotUnitCost.new.exec_migration(ActiveRecord::Base.connection, direction) }
    end
end
