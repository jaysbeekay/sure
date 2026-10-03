class AddStaleValuationDaysToFamilies < ActiveRecord::Migration[8.1]
  def change
    add_column :families, :stale_valuation_days, :integer, default: 90, null: false
    add_check_constraint :families, "stale_valuation_days >= 1 AND stale_valuation_days <= 3650", name: "chk_families_stale_valuation_days"
  end
end
