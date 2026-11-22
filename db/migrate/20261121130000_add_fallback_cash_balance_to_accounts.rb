class AddFallbackCashBalanceToAccounts < ActiveRecord::Migration[8.1]
  def change
    add_column :accounts, :fallback_cash_balance, :decimal, precision: 19, scale: 4
  end
end
