class EnsureEnableBankingPendingTotals < ActiveRecord::Migration[8.1]
  # WidenHoldingLotUnitCost first shipped on this fork as 20261118090000, the
  # version upstream later gave AddPendingTotalsToEnableBankingAccounts. A
  # database that ran the widening under that version records it as run, so
  # the upstream migration never runs there. Add its columns where missing;
  # everywhere else this is a no-op.
  def up
    %i[pending_total anchor_pending_total].each do |column|
      next if column_exists?(:enable_banking_accounts, column)

      add_column :enable_banking_accounts, column, :decimal, precision: 19, scale: 4
    end
  end

  def down
  end
end
