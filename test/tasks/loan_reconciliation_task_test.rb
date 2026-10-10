require "test_helper"

RakeTaskTestHelper.load_task("loans:reconcile_statement", "loan_reconciliation")

# `loans:reconcile_statement` is G2b's private run (#409). These tests feed it
# the synthetic fixture, copied OUT of the repository first, because the task
# refuses a statement inside the working tree.
class LoanReconciliationTaskTest < ActiveSupport::TestCase
  TASK = "loans:reconcile_statement".freeze
  FIXTURE = Rails.root.join("test/fixtures/loan_offset_reconciliation.csv")

  setup do
    RakeTaskTestHelper.prepare(TASK)
    @dir = Dir.mktmpdir
  end

  teardown do
    FileUtils.remove_entry(@dir)
  end

  test "reports the fixture's charges as counts, without echoing the statement" do
    output, exit_error, = run_task(statement(FIXTURE.read))

    assert_nil exit_error
    assert_includes output, "basis: actual_365"
    assert_includes output, "exact: 3/3"
    assert_includes output, "within one cent: 3/3"
    assert_includes output, "largest deviation: 0.00"
    assert_no_match(/2025-|237\.90|93\.68|246\.70|60000|61000/, output, "the report must not carry the statement's dates or amounts")
  end

  test "fails when a charge differs by more than a cent" do
    off = FIXTURE.read.sub("2025-03-06,interest,-93.68,-59346.58", "2025-03-06,interest,-93.70,-59346.60")
                      .gsub(/^(2025-03-(?:06,repayment|18,repayment|18,offset_balance)),([^,]+),(-[\d.]+)/) do
      "#{$1},#{$2},#{format('%.2f', BigDecimal($3) - BigDecimal('0.02'))}"
    end
    off = off.sub("2025-04-06,interest,-246.70,-56093.28", "2025-04-06,interest,-246.70,-56093.30")

    output, exit_error, err = run_task(statement(off))

    assert_failed_exit exit_error
    assert_includes output, "exact: 2/3"
    assert_includes output, "largest deviation: 0.02"
    assert_includes err, "1 of 3 charges differ by more than one cent"
  end

  test "lists a statement's own arithmetic problems and reconciles nothing" do
    broken = FIXTURE.read.sub("2025-01-31,repayment,1000.00,-59000.00", "2025-01-31,repayment,1000.00,-59000.01")

    output, exit_error, err = run_task(statement(broken))

    assert_failed_exit exit_error
    assert_includes output, "row 5: breaks the running balance"
    assert_not_includes output, "exact:"
    assert_includes err, "break its own arithmetic"
  end

  test "honours the day-count basis it is given" do
    output, exit_error, = run_task(statement(FIXTURE.read), "actual_actual")

    assert_nil exit_error
    assert_includes output, "basis: actual_actual"
  end

  test "refuses an unknown day-count basis" do
    _output, exit_error, err = run_task(statement(FIXTURE.read), "actual_364")

    assert_failed_exit exit_error
    assert_includes err, "unsupported day-count convention"
  end

  test "refuses a statement inside the repository" do
    _output, exit_error, err = run_task(FIXTURE.to_s)

    assert_failed_exit exit_error
    assert_includes err, "refusing to read a statement inside the repository"
  end

  test "requires a path" do
    _output, exit_error, err = run_task(nil)

    assert_failed_exit exit_error
    assert_includes err, "usage:"
  end

  private
    def statement(contents)
      File.join(@dir, "statement.csv").tap { |path| File.write(path, contents) }
    end

    def run_task(*args)
      out, err = StringIO.new, StringIO.new
      original_out, original_err = $stdout, $stderr
      $stdout, $stderr = out, err
      exit_error = nil
      begin
        Rake::Task[TASK].invoke(*args)
      rescue SystemExit => error
        exit_error = error
      end
      [ out.string, exit_error, err.string ]
    ensure
      $stdout, $stderr = original_out, original_err
    end

    def assert_failed_exit(exit_error)
      assert exit_error, "the task must exit"
      assert_not exit_error.success?, "the task must exit unsuccessfully"
    end
end
