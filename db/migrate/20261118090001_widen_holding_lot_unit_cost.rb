class WidenHoldingLotUnitCost < ActiveRecord::Migration[8.1]
  # A lot's cost per unit is in the account's currency, and can pass 10^9
  # where the trade's own currency is far stronger; 15 digits before the point
  # matches a holding's cost basis.
  def up
    change_column :holding_lots, :unit_cost, :decimal, precision: 25, scale: 10
    change_column :holding_lot_disposals, :unit_cost, :decimal, precision: 25, scale: 10
  end

  def down
    ensure_narrow_costs_fit!
    change_column :holding_lots, :unit_cost, :decimal, precision: 19, scale: 10
    change_column :holding_lot_disposals, :unit_cost, :decimal, precision: 19, scale: 10
  end

  private

    def ensure_narrow_costs_fit!
      wide = %w[holding_lots holding_lot_disposals].sum do |table|
        select_value("SELECT COUNT(*) FROM #{table} WHERE ABS(unit_cost) >= 1000000000").to_i
      end
      return if wide.zero?

      raise ActiveRecord::IrreversibleMigration, "#{wide} lot costs need the wider unit_cost columns; narrowing them would overflow"
    end
end
