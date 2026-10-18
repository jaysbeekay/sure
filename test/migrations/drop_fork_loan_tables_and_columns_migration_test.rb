# frozen_string_literal: true

require "test_helper"
require Rails.root.join("db/migrate/20261017090000_drop_fork_loan_tables_and_columns")

# The tables and columns this migration drops are gone from schema.rb, so each
# test that needs them builds them with the migration's own `down` first. DDL
# is transactional in PostgreSQL, so the test's rollback puts the schema back.
class DropForkLoanTablesAndColumnsMigrationTest < ActiveSupport::TestCase
  setup do
    @migration = DropForkLoanTablesAndColumns.new
    @loan = loans(:one)
  end

  teardown do
    connection.schema_cache.clear!
    Loan.reset_column_information
  end

  test "down builds the fork's structure empty" do
    quietly { @migration.down }

    DropForkLoanTablesAndColumns::TABLES.each do |table|
      assert connection.table_exists?(table), "#{table} should exist"
      assert_equal 0, rows_in(table)
    end
    assert connection.column_exists?(:loans, :collateral_account_id)
    assert connection.column_exists?(:loans, :day_count_convention, :string, default: "actual_365", null: false)
    assert_equal DropForkLoanTablesAndColumns::LOAN_CHECKS.sort, loan_check_names & DropForkLoanTablesAndColumns::LOAN_CHECKS
  end

  test "up deletes every row and column it names and reports how many it deleted" do
    quietly { @migration.down }
    seed_fork_rows

    output = with_env_overrides(DropForkLoanTablesAndColumns::CONFIRM_ENV => "1") { capture_io { @migration.up }.first }

    { "loan_extra_repayments" => 1, "loan_scenarios" => 1, "loan_offset_accounts" => 1, "loan_amortizations" => 2,
      "loans.collateral_account_id" => 1, "loans.day_count_convention" => 1 }.each do |name, rows|
      assert_match(/#{Regexp.escape(name)}: #{rows} rows? deleted/, output)
    end

    DropForkLoanTablesAndColumns::TABLES.each { |table| assert_not connection.table_exists?(table), "#{table} should be gone" }
    assert_not connection.column_exists?(:loans, :collateral_account_id)
    assert_not connection.column_exists?(:loans, :day_count_convention)
    assert_empty loan_check_names & DropForkLoanTablesAndColumns::LOAN_CHECKS
    assert Loan.exists?(@loan.id), "the loans themselves stay"
  end

  test "up refuses while data a user entered is present, and drops nothing" do
    quietly { @migration.down }
    seed_fork_rows

    [ nil, "0", "yes" ].each do |value|
      error = with_env_overrides(DropForkLoanTablesAndColumns::CONFIRM_ENV => value) do
        assert_raises(DropForkLoanTablesAndColumns::EnteredDataPresent) { quietly { @migration.up } }
      end

      { "loan_extra_repayments" => 1, "loan_scenarios" => 1, "loan_offset_accounts" => 1,
        "loans.collateral_account_id" => 1 }.each do |name, rows|
        assert_match(/#{Regexp.escape(name)}: #{rows}\b/, error.message)
      end
      assert_no_match(/loan_amortizations|day_count_convention/, error.message)
      assert_match(/#{DropForkLoanTablesAndColumns::CONFIRM_ENV}=1/, error.message)
    end

    DropForkLoanTablesAndColumns::TABLES.each { |table| assert connection.table_exists?(table), "#{table} should still exist" }
    assert_equal 1, rows_in("loan_scenarios")
    assert connection.column_exists?(:loans, :collateral_account_id)
    assert connection.column_exists?(:loans, :day_count_convention)
  end

  test "any one kind of entered data is enough to stop it" do
    quietly { @migration.down }
    loan_id = connection.quote(@loan.id)

    {
      "an offset link" => "INSERT INTO loan_offset_accounts (loan_id, account_id, created_at, updated_at) " \
                          "VALUES (#{loan_id}, #{connection.quote(accounts(:depository).id)}, now(), now())",
      "a collateral link" => "UPDATE loans SET collateral_account_id = #{connection.quote(accounts(:property).id)} WHERE id = #{loan_id}",
      "a saved scenario" => "INSERT INTO loan_scenarios (loan_id, name, slot, currency, calculator_version, created_at, updated_at) " \
                            "VALUES (#{loan_id}, 'Pay more', 0, 'USD', 1, now(), now())"
    }.each do |kind, sql|
      connection.transaction(requires_new: true) do
        connection.execute(sql)
        assert_raises(DropForkLoanTablesAndColumns::EnteredDataPresent, kind) { quietly { @migration.up } }
        raise ActiveRecord::Rollback
      end
    end
  end

  # The amortisation rows were derived and upstream recomputes them; upstream has
  # no day-count setting to carry a choice over to. Neither is worth stopping for.
  test "derived amortisation rows and a day-count choice alone do not stop it" do
    quietly { @migration.down }
    loan_id = connection.quote(@loan.id)
    connection.execute(<<~SQL)
      UPDATE loans SET day_count_convention = 'actual_actual' WHERE id = #{loan_id};
      INSERT INTO loan_amortizations (loan_id, payment_number, payment_date, payment_amount, principal_payment, interest_payment,
                                      beginning_balance, ending_balance, interest_rate, schedule_signature, created_at, updated_at)
        VALUES (#{loan_id}, 1, '2026-01-01', 100, 90, 10, 1000, 910, 5, 'sig', now(), now());
    SQL

    output = with_env_overrides(DropForkLoanTablesAndColumns::CONFIRM_ENV => nil) { capture_io { @migration.up }.first }

    assert_match(/loan_amortizations: 1 row deleted/, output)
    assert_match(/loans\.day_count_convention: 1 row deleted/, output)
    assert_not connection.table_exists?(:loan_amortizations)
  end

  # A day-count of the default is every loan's value, not a choice anyone made.
  test "a loan left on the default day-count is not counted as a lost choice" do
    quietly { @migration.down }

    assert_equal 0, @migration.dropped_counts["loans.day_count_convention"]

    connection.execute("UPDATE loans SET day_count_convention = 'actual_actual' WHERE id = #{connection.quote(@loan.id)}")
    assert_equal 1, @migration.dropped_counts["loans.day_count_convention"]
  end

  # A database built from migrations never had any of it: up must neither raise
  # nor report anything.
  test "up on a database without the fork's structure changes nothing" do
    assert_equal({}, @migration.dropped_counts)

    output = capture_io { assert_nothing_raised { @migration.up } }.first

    assert_no_match(/deleted/, output)
  end

  private
    def connection
      ActiveRecord::Base.connection
    end

    def quietly(&block)
      capture_io(&block)
    end

    def rows_in(table)
      connection.select_value("SELECT COUNT(*) FROM #{table}").to_i
    end

    def loan_check_names
      connection.check_constraints(:loans).map(&:name)
    end

    # One row in each table (two amortisation rows), one collateral link and one
    # day-count choice. The other loans keep their defaults, so each count is
    # exactly what this seeded.
    def seed_fork_rows
      loan_id = connection.quote(@loan.id)
      collateral_id = connection.quote(accounts(:property).id)
      offset_id = connection.quote(accounts(:depository).id)
      user_id = connection.quote(users(:family_admin).id)

      connection.execute(<<~SQL)
        UPDATE loans SET collateral_account_id = #{collateral_id}, day_count_convention = 'actual_actual' WHERE id = #{loan_id};
        INSERT INTO loan_offset_accounts (loan_id, account_id, created_at, updated_at) VALUES (#{loan_id}, #{offset_id}, now(), now());
        INSERT INTO loan_amortizations (loan_id, payment_number, payment_date, payment_amount, principal_payment, interest_payment,
                                        beginning_balance, ending_balance, interest_rate, schedule_signature, created_at, updated_at)
          VALUES (#{loan_id}, 1, '2026-01-01', 100, 90, 10, 1000, 910, 5, 'sig', now(), now()),
                 (#{loan_id}, 2, '2026-02-01', 100, 91, 9, 910, 819, 5, 'sig', now(), now());
      SQL
      scenario_id = connection.select_value(<<~SQL)
        INSERT INTO loan_scenarios (loan_id, created_by_user_id, name, slot, currency, calculator_version, created_at, updated_at)
          VALUES (#{loan_id}, #{user_id}, 'Pay more', 0, 'USD', 1, now(), now()) RETURNING id
      SQL
      connection.execute(<<~SQL)
        INSERT INTO loan_extra_repayments (loan_scenario_id, kind, amount, frequency, starts_on, created_at, updated_at)
          VALUES (#{connection.quote(scenario_id)}, 'recurring', 200, 'monthly', '2026-01-01', now(), now())
      SQL
    end
end
