# The fork added index_taggings_unique as a column index with NULLS NOT
# DISTINCT. Upstream's reviewed version (20261007120000) keys
# COALESCE(taggable_type, '') instead, so a missing and an empty type count as
# the same object, which is how Tag#replace_and_destroy! now compares them.
# Upstream's migration adds the index only if none exists, so on a database
# that ran the fork's it does nothing. This rebuilds the fork's index in
# upstream's form; where upstream's is already there it does nothing.
class ConvergeTaggingsUniqueIndex < ActiveRecord::Migration[8.1]
  def up
    existing = connection.indexes(:taggings).find { |index| index.name == "index_taggings_unique" }
    return if existing && existing.columns.is_a?(String)

    # As in upstream's migration: writers wait until the index is rebuilt.
    execute "LOCK TABLE taggings IN SHARE ROW EXCLUSIVE MODE"

    # The fork's index let a NULL-type row and an empty-type row for the same
    # object both stand; upstream's refuses the second, so remove it first.
    execute <<~SQL
      DELETE FROM taggings
      WHERE id IN (
        SELECT id FROM (
          SELECT id, ROW_NUMBER() OVER (
            PARTITION BY tag_id, COALESCE(taggable_type, ''), taggable_id
            ORDER BY created_at, id
          ) AS position
          FROM taggings
          WHERE taggable_id IS NOT NULL
        ) ranked
        WHERE position > 1
      )
    SQL

    remove_index :taggings, name: "index_taggings_unique", if_exists: true
    add_index :taggings, "tag_id, COALESCE(taggable_type, ''), taggable_id",
      name: "index_taggings_unique",
      unique: true,
      where: "taggable_id IS NOT NULL"
  end

  # The removed duplicates are not kept anywhere, and the index this replaces
  # admitted only rows the new one also admits, so there is nothing to undo.
  def down
  end
end
