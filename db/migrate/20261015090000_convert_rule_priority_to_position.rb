# frozen_string_literal: true

# Fork only. The fork ordered rules by `priority` (20261001090000) and ran them
# in ascending `(priority, created_at, id)` order, each rule overwriting what
# the ones before it set, so the LAST rule in that order won. Upstream's
# 20261006140000 adds `position` instead, numbers existing rules A-Z by name,
# and runs them top to bottom with the FIRST (lowest position) rule winning.
#
# Left at upstream's A-Z numbering, a family whose two rules set the same field
# could see the other rule win after the upgrade. This renumbers each family's
# rules in the exact reverse of the fork's order, so the rule that used to run
# last -- the one whose value stuck -- is now at the top, where it still wins:
#
#   position = ROW_NUMBER() OVER (PARTITION BY family_id
#                                 ORDER BY priority DESC, created_at DESC, id DESC)
#
# The fork's order was total (created_at and id broke priority ties), so the
# reversal is too, and every family's positions come out as 1..n.
#
# What a reversal cannot preserve is a chain: a rule that matched on a value an
# earlier rule wrote (a rename, then a rule matching the new name) now runs
# before the rule it depended on. Drag-to-reorder fixes such a pair by hand.
class ConvertRulePriorityToPosition < ActiveRecord::Migration[8.1]
  def up
    return unless column_exists?(:rules, :priority)

    execute <<~SQL
      UPDATE rules SET position = ranked.rn
      FROM (
        SELECT id, ROW_NUMBER() OVER (
          PARTITION BY family_id ORDER BY priority DESC, created_at DESC, id DESC
        ) AS rn
        FROM rules
      ) ranked
      WHERE rules.id = ranked.id
    SQL

    remove_index :rules, [ :family_id, :priority ], if_exists: true
    remove_column :rules, :priority
  end

  # Restores the fork's column, ranked so that the top rule (which wins under
  # `position`) runs last again (where it won under `priority`).
  def down
    add_column :rules, :priority, :integer, null: false, default: 0

    execute <<~SQL
      UPDATE rules SET priority = ranked.rn
      FROM (
        SELECT id, ROW_NUMBER() OVER (
          PARTITION BY family_id ORDER BY position DESC, created_at DESC, id DESC
        ) AS rn
        FROM rules
      ) ranked
      WHERE rules.id = ranked.id
    SQL

    add_index :rules, [ :family_id, :priority ]
  end
end
