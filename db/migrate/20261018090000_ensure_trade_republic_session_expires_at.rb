# frozen_string_literal: true

# Fork only. Upstream's 20261015090000 adds this column, but the fork's rule
# position migration first shipped under the same version, so a fork database
# that ran it has 20261015090000 recorded and skips upstream's. The fork's
# migration now carries 20261015090001 (it returns early once `priority` is
# gone, so running it again is a no-op), and this adds the column where
# upstream's migration was skipped. On a fresh database it does nothing.
class EnsureTradeRepublicSessionExpiresAt < ActiveRecord::Migration[8.1]
  def up
    return if column_exists?(:trade_republic_items, :session_expires_at)

    add_column :trade_republic_items, :session_expires_at, :datetime
  end

  def down
    # Nothing to undo: the column belongs to upstream's 20261015090000.
  end
end
