class AddRateChangeSupportToLoans < ActiveRecord::Migration[7.2]
  def change
    add_column :loans, :rate_change_schedule, :jsonb, default: {}, null: false
    add_column :loans, :next_rate_change_date, :date

    add_index :loans, :next_rate_change_date
  end
end
