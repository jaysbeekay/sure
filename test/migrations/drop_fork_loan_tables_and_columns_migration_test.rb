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
    assert_equal FORK_DAY_COUNT_CHECK, day_count_check_expression
  end

  test "up deletes every row and column it names and reports how many it deleted" do
    quietly { @migration.down }
    seed_fork_rows

    output = with_env_overrides(DropForkLoanTablesAndColumns::CONFIRM_ENV => "1") { capture_io { @migration.up }.first }

    { "loan_extra_repayments" => 1, "loan_scenarios" => 1, "loan_offset_accounts" => 1, "loan_amortizations" => 2,
      "loans.collateral_account_id" => 1 }.each do |name, rows|
      assert_match(/#{Regexp.escape(name)}: #{rows} rows? deleted/, output)
    end
    assert_no_match(/day_count_convention: \d+ rows? deleted/, output)

    DropForkLoanTablesAndColumns::TABLES.each { |table| assert_not connection.table_exists?(table), "#{table} should be gone" }
    assert_not connection.column_exists?(:loans, :collateral_account_id)
    assert_empty loan_check_names & DropForkLoanTablesAndColumns::LOAN_CHECKS
    assert Loan.exists?(@loan.id), "the loans themselves stay"
    assert_equal "actual_actual", day_count_of(@loan), "the day-count choice is kept, not deleted"
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

  # The amortisation rows were derived and upstream recomputes them, and the
  # day-count choice is kept rather than deleted. Neither is worth stopping for.
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
    assert_no_match(/day_count_convention: \d+ rows? deleted/, output)
    assert_not connection.table_exists?(:loan_amortizations)
    assert_equal "actual_actual", day_count_of(@loan)
  end

  # Upstream's loan (we-promise/sure#3639) reads this same column, with a third
  # value, thirty_360, as the default for a new loan. Every value the fork could
  # hold is one of upstream's, so each existing loan keeps the basis it was
  # entered on; only the check and the default for new rows change.
  test "up keeps each loan's day-count and takes upstream's check and default" do
    quietly { @migration.down }
    # A second loan left on the fork's default; the fixtures hold only one.
    other = Loan.new(id: connection.select_value("INSERT INTO loans (created_at, updated_at) VALUES (now(), now()) RETURNING id"))
    connection.execute("UPDATE loans SET day_count_convention = 'actual_actual' WHERE id = #{connection.quote(@loan.id)}")
    assert_equal "actual_365", day_count_of(other), "precondition: the fork's default"
    assert_raises(ActiveRecord::StatementInvalid, "precondition: the fork's check refuses thirty_360") do
      connection.transaction(requires_new: true) { set_day_count(other, "thirty_360") }
    end

    quietly { @migration.up }

    assert_equal "actual_actual", day_count_of(@loan)
    assert_equal "actual_365", day_count_of(other)
    assert connection.column_exists?(:loans, :day_count_convention, :string, default: "thirty_360", null: false)
    assert_equal UPSTREAM_DAY_COUNT_CHECK, day_count_check_expression

    assert_nothing_raised { set_day_count(other, "thirty_360") }
    assert_raises(ActiveRecord::StatementInvalid) do
      connection.transaction(requires_new: true) { set_day_count(other, "actual_360") }
    end
  end

  # Built from migrations alone, before upstream's own migration arrives, the
  # column was never created. up gives it upstream's shape, so every database
  # ends this migration with the same column.
  test "up adds the day-count column in upstream's shape where it is missing" do
    connection.remove_check_constraint :loans, name: "chk_loans_day_count_convention", if_exists: true
    connection.remove_column :loans, :day_count_convention, if_exists: true

    quietly { @migration.up }

    assert connection.column_exists?(:loans, :day_count_convention, :string, default: "thirty_360", null: false)
    assert_equal UPSTREAM_DAY_COUNT_CHECK, day_count_check_expression
    assert_equal "thirty_360", day_count_of(@loan)
  end

  # Rolled back to the fork's engine, which knows only its two conventions.
  test "down after up restores the fork's check, default and choices" do
    quietly { @migration.down }
    connection.execute("UPDATE loans SET day_count_convention = 'actual_actual' WHERE id = #{connection.quote(@loan.id)}")
    quietly { @migration.up }

    quietly { @migration.down }

    assert_equal "actual_actual", day_count_of(@loan)
    assert connection.column_exists?(:loans, :day_count_convention, :string, default: "actual_365", null: false)
    assert_equal FORK_DAY_COUNT_CHECK, day_count_check_expression
  end

  # A database built from migrations never had any of it: up must neither raise
  # nor report anything.
  test "up on a database without the fork's structure changes nothing" do
    assert_equal({}, @migration.dropped_counts)

    output = capture_io { assert_nothing_raised { @migration.up } }.first

    assert_no_match(/deleted/, output)
    assert connection.column_exists?(:loans, :day_count_convention, :string, default: "thirty_360", null: false)
    assert_equal UPSTREAM_DAY_COUNT_CHECK, day_count_check_expression
  end

  # As upstream's schema.rb dumps it, after its 20260918210000.
  UPSTREAM_DAY_COUNT_CHECK = "day_count_convention::text = ANY (ARRAY['thirty_360'::character varying, " \
                             "'actual_365'::character varying, 'actual_actual'::character varying]::text[])"
  # As fork main's schema.rb dumps it, after its 20260907000000.
  FORK_DAY_COUNT_CHECK = "day_count_convention::text = ANY (ARRAY['actual_365'::character varying::text, " \
                         "'actual_actual'::character varying::text])"

  private
    def day_count_check_expression
      connection.check_constraints(:loans).find { |check| check.name == "chk_loans_day_count_convention" }&.expression
    end

    def day_count_of(loan)
      connection.select_value("SELECT day_count_convention FROM loans WHERE id = #{connection.quote(loan.id)}")
    end

    def set_day_count(loan, value)
      connection.execute("UPDATE loans SET day_count_convention = #{connection.quote(value)} WHERE id = #{connection.quote(loan.id)}")
    end

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
