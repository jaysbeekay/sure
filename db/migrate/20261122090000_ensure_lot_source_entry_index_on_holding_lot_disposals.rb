# The fork created holding_lot_disposals before upstream reviewed it. Upstream's
# reviewed create migration, which keeps the same version, also indexes
# lot_source_entry_id, so that deleting an entry can find the disposals its
# :nullify foreign key has to clear. A database that ran the fork's version
# has that version recorded and never gets the index. On a fresh database the
# create migration has already added it, and this does nothing.
class EnsureLotSourceEntryIndexOnHoldingLotDisposals < ActiveRecord::Migration[8.1]
  def change
    add_index :holding_lot_disposals, :lot_source_entry_id, if_not_exists: true
  end
end
