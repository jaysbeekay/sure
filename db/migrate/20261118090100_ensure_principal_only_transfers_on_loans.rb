class EnsurePrincipalOnlyTransfersOnLoans < ActiveRecord::Migration[8.1]
  # Upstream's AddPrincipalOnlyTransfersToLoans shares version 20261025090000
  # with this fork's WidenHoldingLotUnitCost (now 20261118090001). A database
  # that ran the widen migration under that version records it as run, so
  # upstream's migration never runs there. This adds the column in that case
  # and does nothing where upstream's migration already added it.
  def up
    return if column_exists?(:loans, :principal_only_transfers)

    add_column :loans, :principal_only_transfers, :boolean, default: false, null: false
  end

  def down
    # The column belongs to upstream's migration; leave it in place.
  end
end
