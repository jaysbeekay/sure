# frozen_string_literal: true

# Schema for classifying a security by asset class, sub-class, sector, industry
# and region, with provenance and a lock so a user's manual classification is
# not overwritten by a provider or a default.
#
# Schema only. Nothing reads or writes the columns until a later drop, so
# every value stays NULL and the migration carries no data risk.
#
# The enumerated columns are plain strings with a check constraint, matching
# `securities.kind` (`chk_securities_kind`) and `loans.day_count_convention`:
# adding a value later is a constraint swap, not a type change. The permitted
# values are the six-class / twelve-sub-class taxonomy other portfolio trackers
# use, so an import maps onto them without a translation table.
#
# Written as explicit up/down rather than `change` because the constraints are
# added NOT VALID and validated afterwards. On PostgreSQL that is two short
# locks instead of one full-table scan under an exclusive lock; it needs
# `disable_ddl_transaction!` to mean anything, and `validate_check_constraint`
# has no inverse for a `change` block to record.
class AddClassificationToSecurities < ActiveRecord::Migration[7.2]
  disable_ddl_transaction!

  ASSET_CLASSES = %w[
    alternative_investment commodity equity fixed_income liquidity real_estate
  ].freeze

  ASSET_SUB_CLASSES = %w[
    bond cash collectible commodity cryptocurrency etf loan mutual_fund
    precious_metal private_equity real_estate stock
  ].freeze

  CLASSIFICATION_SOURCES = %w[provider manual ai default].freeze

  CONSTRAINTS = {
    "chk_securities_asset_class" => [ "asset_class", ASSET_CLASSES ],
    "chk_securities_asset_sub_class" => [ "asset_sub_class", ASSET_SUB_CLASSES ],
    "chk_securities_classification_source" => [ "classification_source", CLASSIFICATION_SOURCES ]
  }.freeze

  def up
    add_column :securities, :asset_class, :string
    add_column :securities, :asset_sub_class, :string
    add_column :securities, :sector, :string
    add_column :securities, :industry, :string
    add_column :securities, :region, :string
    add_column :securities, :classification_source, :string
    # A boolean with a constant default is a catalog-only change on
    # PostgreSQL 11+; existing rows are not rewritten. The project ships
    # PostgreSQL 16 (compose.example.yml, .devcontainer) and the existing
    # loans migrations rely on the same behaviour.
    add_column :securities, :classification_locked, :boolean, null: false, default: false

    CONSTRAINTS.each do |name, (column, values)|
      add_check_constraint :securities, "#{column} IN (#{values.map { |v| "'#{v}'" }.join(', ')})",
        name: name, validate: false
    end

    CONSTRAINTS.each_key do |name|
      validate_check_constraint :securities, name: name
    end
  end

  def down
    CONSTRAINTS.each_key do |name|
      remove_check_constraint :securities, name: name
    end

    remove_column :securities, :classification_locked
    remove_column :securities, :classification_source
    remove_column :securities, :region
    remove_column :securities, :industry
    remove_column :securities, :sector
    remove_column :securities, :asset_sub_class
    remove_column :securities, :asset_class
  end
end
