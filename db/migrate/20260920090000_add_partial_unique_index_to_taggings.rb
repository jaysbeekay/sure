# Issue #202 — `taggings` has no uniqueness constraint, so a tag can
# applied twice to one object. `Tag#replace_and_destroy!` merges by
# `taggings.update_all tag_id: replacement.id`, which for an object that
# already carries the replacement produces two identical rows, and a
# concurrent check-then-insert can interleave the same way.
#
# A plain unique index on (tag_id, taggable_type, taggable_id) would not
# hold: both taggable columns are nullable, and Postgres treats NULLs as
# distinct in unique indexes, so duplicate rows with a NULL taggable
# would pass it unnoticed. The partial index constrains exactly the rows
# that represent a real tagging, with the same predicate the dedupe
# below applies.
#
# `nulls_not_distinct` is what makes the index hold for a row whose
# taggable_id is set but whose taggable_type is NULL: Postgres's default
# treats two such rows as distinct keys and admits the duplicate the
# index exists to refuse. PostgreSQL 15+ only, which this application
# already requires.
#
# Dedupe keeps MIN(id) per (tag_id, taggable_type, taggable_id) and runs
# before the index so it never meets a pre-existing duplicate. It
# compares the type with IS NOT DISTINCT FROM rather than `=` for the
# same reason: `NULL = NULL` is NULL, so a plain equality join would step
# over exactly the duplicates the index is about to reject, and the
# migration would fail on the data it was written to clean.
#
# The migration's transaction (the default) also closes the race: a plain
# CREATE UNIQUE INDEX takes ShareLock -- NOT ShareUpdateExclusiveLock, as
# an earlier version of this comment said -- and ShareLock conflicts with
# RowExclusiveLock, so writers are blocked and a duplicate insert cannot
# land between the two statements. The conclusion was right; the lock
# name was wrong.
class AddPartialUniqueIndexToTaggings < ActiveRecord::Migration[8.1]
  def up
    execute <<~SQL
      DELETE FROM taggings AS duplicate
      USING taggings AS keeper
      WHERE keeper.tag_id = duplicate.tag_id
        AND keeper.taggable_type IS NOT DISTINCT FROM duplicate.taggable_type
        AND keeper.taggable_id = duplicate.taggable_id
        AND keeper.id < duplicate.id
        AND duplicate.taggable_id IS NOT NULL
    SQL

    add_index :taggings, [ :tag_id, :taggable_type, :taggable_id ],
      name: "index_taggings_unique",
      unique: true,
      nulls_not_distinct: true,
      where: "taggable_id IS NOT NULL"
  end

  # The removed duplicate rows are not recorded anywhere, so a rollback
  # could not restore them — the same position as the other data-removal
  # migrations in this repository.
  def down
    raise ActiveRecord::IrreversibleMigration,
          "Removed duplicate taggings cannot be restored"
  end
end
