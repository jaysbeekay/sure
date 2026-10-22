# Removes the fork's own loan engine storage, which upstream's loan code does
# not use: offset links, collateral links, saved scenarios and their extra
# repayments, the persisted amortisation rows and the fork's bounds checks on
# `loans`. THE DATA IN THEM IS DELETED; only the amortisation rows are derived,
# and upstream's schedule recomputes those.
#
# `loans.day_count_convention` is KEPT, with every loan's value. Upstream's
# loan (we-promise/sure#3639, its 20260918210000) has the same column with a
# third value, thirty_360, which is its default for a new loan. Both of the
# fork's values are among upstream's, so this swaps the fork's two-value check
# for upstream's three-value one under the same name and takes upstream's
# default for new rows. An existing loan stays on actual_365 or actual_actual.
# A database without the column, built from migrations alone, gets it in that
# same shape, so every database leaves here with the column upstream expects.
#
# Each table and column is counted before it goes, and the counts are written
# to the migration output and the log, so an installation can see what it lost.
# If any of it is data a user entered (ENTERED), the migration stops instead,
# naming what it found, until FORK_LOAN_DROP_CONFIRMED=1 is set.
#
# `if_exists` throughout the drops: a database built from migrations alone never
# created these, because the migrations that did were removed with the code.
class DropForkLoanTablesAndColumns < ActiveRecord::Migration[8.1]
  # In drop order: loan_extra_repayments references loan_scenarios.
  TABLES = %w[loan_extra_repayments loan_scenarios loan_offset_accounts loan_amortizations].freeze

  LOAN_CHECKS = %w[chk_loans_interest_rate_bounds chk_loans_term_months_bounds].freeze

  # Upstream's, word for word, so the check and schema.rb agree with upstream's.
  DAY_COUNT_CHECK = "chk_loans_day_count_convention"
  DAY_COUNT_CONVENTIONS = %w[thirty_360 actual_365 actual_actual].freeze
  DAY_COUNT_DEFAULT = "thirty_360"
  FORK_DAY_COUNT_CONVENTIONS = %w[actual_365 actual_actual].freeze
  FORK_DAY_COUNT_DEFAULT = "actual_365"

  # What a user entered rather than what the app derived. Any of it present
  # stops the migration unless the deletion is confirmed. The amortisation rows
  # are recomputed upstream. The day-count choice is kept, so it is not here.
  ENTERED = %w[loan_extra_repayments loan_scenarios loan_offset_accounts loans.collateral_account_id].freeze
  CONFIRM_ENV = "FORK_LOAN_DROP_CONFIRMED"

  class EnteredDataPresent < StandardError; end

  def up
    counts = dropped_counts
    refuse_unconfirmed_deletion(counts)
    report_dropped_counts(counts)

    TABLES.each { |table| drop_table table, if_exists: true }

    LOAN_CHECKS.each { |name| remove_check_constraint :loans, name: name, if_exists: true }
    # Dropping the column drops its index and foreign key with it.
    remove_column :loans, :collateral_account_id, if_exists: true

    adopt_upstream_day_count
  end

  # The empty structure only. The rows are gone.
  def down
    add_column :loans, :collateral_account_id, :uuid, if_not_exists: true
    add_index :loans, :collateral_account_id, if_not_exists: true
    add_foreign_key :loans, :accounts, column: :collateral_account_id, on_delete: :nullify, if_not_exists: true
    restore_fork_day_count
    add_check_constraint :loans, "interest_rate IS NULL OR interest_rate >= 0::numeric AND interest_rate <= 100::numeric",
                         name: "chk_loans_interest_rate_bounds", if_not_exists: true
    add_check_constraint :loans, "term_months IS NULL OR term_months > 0 AND term_months <= 1200",
                         name: "chk_loans_term_months_bounds", if_not_exists: true

    create_table :loan_amortizations, id: :uuid, if_not_exists: true do |t|
      t.integer :algorithm_version, default: 2, null: false
      t.decimal :beginning_balance, precision: 19, scale: 4, null: false
      t.decimal :ending_balance, precision: 19, scale: 4, null: false
      t.datetime :generated_at, default: -> { "CURRENT_TIMESTAMP" }, null: false
      t.decimal :interest_payment, precision: 19, scale: 4, null: false
      t.decimal :interest_rate, precision: 10, scale: 3, null: false
      t.references :loan, type: :uuid, null: false, foreign_key: true
      t.decimal :payment_amount, precision: 19, scale: 4, null: false
      t.date :payment_date, null: false
      t.integer :payment_number, null: false
      t.decimal :principal_payment, precision: 19, scale: 4, null: false
      t.string :schedule_signature, null: false
      t.timestamps
      t.index %i[algorithm_version loan_id]
      t.index %i[loan_id algorithm_version]
      t.index %i[loan_id payment_date]
      t.index %i[loan_id payment_number], unique: true
      t.index %i[loan_id schedule_signature]
      t.check_constraint "beginning_balance >= 0::numeric", name: "chk_loan_amortizations_beginning_balance_non_negative"
      t.check_constraint "ending_balance >= 0::numeric", name: "chk_loan_amortizations_ending_balance_non_negative"
      t.check_constraint "interest_payment >= 0::numeric", name: "chk_loan_amortizations_interest_payment_non_negative"
      t.check_constraint "interest_rate >= 0::numeric AND interest_rate <= 100::numeric", name: "chk_loan_amortizations_interest_rate_bounds"
      t.check_constraint "payment_amount >= 0::numeric", name: "chk_loan_amortizations_payment_amount_non_negative"
      t.check_constraint "payment_number > 0", name: "chk_loan_amortizations_payment_number_positive"
      t.check_constraint "principal_payment >= 0::numeric", name: "chk_loan_amortizations_principal_payment_non_negative"
    end

    create_table :loan_offset_accounts, id: :uuid, if_not_exists: true do |t|
      t.references :account, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :loan, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.timestamps
      t.index %i[loan_id account_id], unique: true
    end

    create_table :loan_scenarios, id: :uuid, if_not_exists: true do |t|
      t.decimal :assumed_offset_balance, precision: 19, scale: 4
      t.integer :calculator_version, null: false
      t.references :created_by_user, type: :uuid, foreign_key: { to_table: :users, on_delete: :nullify }
      t.string :currency, null: false
      t.datetime :last_calculated_at
      t.references :loan, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.string :name, limit: 100, null: false
      t.decimal :rate_override, precision: 10, scale: 3
      t.integer :slot, null: false
      t.timestamps
      t.index %i[loan_id slot], unique: true
      t.check_constraint "assumed_offset_balance IS NULL OR assumed_offset_balance >= 0::numeric", name: "chk_loan_scenarios_offset_non_negative"
      t.check_constraint "rate_override IS NULL OR rate_override >= 0::numeric AND rate_override <= 100::numeric", name: "chk_loan_scenarios_rate_override_range"
      t.check_constraint "slot >= 0 AND slot <= 4", name: "chk_loan_scenarios_slot_range"
    end

    create_table :loan_extra_repayments, id: :uuid, if_not_exists: true do |t|
      t.decimal :amount, precision: 19, scale: 4, null: false
      t.date :ends_on
      t.string :frequency
      t.integer :interval, default: 1
      t.string :kind, null: false
      t.references :loan_scenario, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.date :occurs_on
      t.date :starts_on
      t.timestamps
      t.check_constraint "\"interval\" IS NULL OR \"interval\" > 0", name: "chk_loan_extra_repayments_interval_positive"
      t.check_constraint "amount > 0::numeric", name: "chk_loan_extra_repayments_amount_positive"
      t.check_constraint "frequency IS NULL OR frequency IN ('weekly', 'fortnightly', 'monthly', 'quarterly', 'yearly')", name: "chk_loan_extra_repayments_frequency"
      t.check_constraint "kind::text <> 'recurring'::text OR starts_on IS NOT NULL", name: "chk_loan_extra_repayments_recurring_has_start"
      t.check_constraint "kind::text = 'one_off'::text AND occurs_on IS NOT NULL AND frequency IS NULL OR kind::text = 'recurring'::text AND frequency IS NOT NULL AND occurs_on IS NULL", name: "chk_loan_extra_repayments_kind_coherent"
      t.check_constraint "starts_on IS NULL OR ends_on IS NULL OR ends_on >= starts_on", name: "chk_loan_extra_repayments_date_order"
    end
  end

  # What `up` is about to delete, keyed as it is reported. A table or column
  # that is not there counts nothing and is left out. Asked of the connection
  # directly: through the migration each check would print a line of its own.
  def dropped_counts
    counts = TABLES.select { |table| connection.table_exists?(table) }.index_with { |table| count("SELECT COUNT(*) FROM #{table}") }

    if connection.column_exists?(:loans, :collateral_account_id)
      counts["loans.collateral_account_id"] = count("SELECT COUNT(*) FROM loans WHERE collateral_account_id IS NOT NULL")
    end
    counts
  end

  private
    # Keeps the column and every value in it. Only the check and the default
    # for a new row change.
    def adopt_upstream_day_count
      add_column :loans, :day_count_convention, :string, default: DAY_COUNT_DEFAULT, null: false, if_not_exists: true
      change_column_default :loans, :day_count_convention, DAY_COUNT_DEFAULT
      remove_check_constraint :loans, name: DAY_COUNT_CHECK, if_exists: true
      add_check_constraint :loans, "day_count_convention IN (#{quoted(DAY_COUNT_CONVENTIONS)})", name: DAY_COUNT_CHECK
    end

    # The fork's engine knows two conventions. A loan created on thirty_360
    # since `up` goes to the fork's default; every other choice is kept.
    def restore_fork_day_count
      add_column :loans, :day_count_convention, :string, default: FORK_DAY_COUNT_DEFAULT, null: false, if_not_exists: true
      remove_check_constraint :loans, name: DAY_COUNT_CHECK, if_exists: true
      execute <<~SQL.squish
        UPDATE loans SET day_count_convention = #{connection.quote(FORK_DAY_COUNT_DEFAULT)}
        WHERE day_count_convention NOT IN (#{quoted(FORK_DAY_COUNT_CONVENTIONS)})
      SQL
      change_column_default :loans, :day_count_convention, FORK_DAY_COUNT_DEFAULT
      add_check_constraint :loans, "day_count_convention::text = ANY (ARRAY['actual_365'::character varying::text, 'actual_actual'::character varying::text])",
                           name: DAY_COUNT_CHECK
    end

    def quoted(values)
      values.map { |value| connection.quote(value) }.join(", ")
    end

    def refuse_unconfirmed_deletion(counts)
      return if ENV[CONFIRM_ENV] == "1"

      entered = counts.slice(*ENTERED).select { |_name, rows| rows.positive? }
      return if entered.empty?

      raise EnteredDataPresent, <<~MESSAGE
        This migration deletes the fork's loan data, and this database holds some that a user entered:
        #{entered.map { |name, rows| "  #{name}: #{rows}" }.join("\n")}
        Back it up if you need it, then run the migration again with #{CONFIRM_ENV}=1 to delete it.
      MESSAGE
    end

    def report_dropped_counts(counts)
      counts.each do |name, rows|
        message = "#{name}: #{rows} #{rows == 1 ? "row" : "rows"} deleted"
        say message
        Rails.logger.info("[DropForkLoanTablesAndColumns] #{message}")
      end
    end

    def count(sql)
      connection.select_value(sql).to_i
    end
end
