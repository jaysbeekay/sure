require "test_helper"

# Gate G2b, the offset half of lender reconciliation (#409).
#
# The fixture is SYNTHETIC, for the reason docs/loans/methodology.md gives for
# G2a's: a statement, and an offset account's daily balances, identify a
# borrower even with names and account numbers removed. The real run happens
# outside the repository with `loans:reconcile_statement`, which reads the same
# shape through the same Loan::StatementReconciliation; only its summary comes
# back.
#
# The fixture's charges were computed independently of the engine, by a
# day-by-day loop over the formula:
#
#   interest(D) = max(0, loan balance at end of D - offset total at end of D)
#                 x rate on D / 100 / 365
#
# summed over each charge window and rounded once, half-up, to cents. So the
# expected figures are not the engine's own output played back.
class Loan::OffsetReconciliationTest < ActiveSupport::TestCase
  FIXTURE = Rails.root.join("test/fixtures/loan_offset_reconciliation.csv")

  # Structural de-identification guard, an allowlist for the reason G2a's is:
  # a denylist would have to write the identifiers into the test.
  test "fixture holds only ISO dates, known categories and decimal amounts" do
    lines = File.read(FIXTURE).lines.map(&:chomp).reject(&:empty?)

    assert_equal Loan::StatementReconciliation::HEADERS.join(","), lines.first
    assert_empty deidentification_violations(lines.drop(1))
  end

  test "the guard rejects a row carrying a free-text token" do
    clean = "2025-01-06,repayment,100.00,-59900.00,6.10,0.00"

    assert_empty deidentification_violations([ clean ]), "the clean row must pass, or the rejections below prove nothing"
    assert_equal 1, deidentification_violations([ "2025-01-06,transfer from j smith,100.00,-59900.00,6.10,0.00" ]).length
    assert_equal 1, deidentification_violations([ "2025-01-06,repayment,100.00,-59900.00,6.10,ACC 123" ]).length
    assert_equal 1, deidentification_violations([ "06/01/2025,repayment,100.00,-59900.00,6.10,0.00" ]).length
    assert_equal 1, deidentification_violations([ "2025-01-06,repayment,100.00,-59900.00,6.10,0.00,memo" ]).length
  end

  test "fixture is internally consistent" do
    assert_empty reconciliation.problems
  end

  test "fixture covers the offset cases G2b must show" do
    windows = reconciliation.windows

    assert_equal 3, windows.length, "the fixture must retain three charge windows"

    above_balance = rows.find { |row| row["category"] == "offset_balance" && row["offset"].to_d > row["balance"].to_d.abs }
    assert above_balance, "C15: an offset above the loan balance"

    window_starts = windows.map { |window| window[:from_date] }
    assert rows.any? { |row| row["category"] == "offset_balance" && Date.iso8601(row["date"]).in?(window_starts) },
      "C16: an offset change on a charge window's first day"

    assert rows.any? { |row| row["category"] == "rate_change" }, "a rate change inside a window"
    assert rows.group_by { |row| row["date"] }.any? { |_date, same_day| same_day.map { |row| row["category"] }.to_set >= %w[repayment offset_balance].to_set },
      "a repayment and an offset move on the same day"
  end

  # The G2b oracle. Each fixture charge must equal the engine's piecewise
  # accrual over that window's balance, rate and offset segments, rounded once.
  test "every offset-reduced charge in the fixture reconciles through Loan::InterestAccrual" do
    charges = reconciliation.charges

    assert_equal %w[237.90 93.68 246.70].map { |amount| BigDecimal(amount) }, charges.map(&:expected)
    charges.each do |charge|
      assert_equal charge.expected, charge.actual, "charge on #{charge.date}"
    end
    assert_equal({ compared: 3, exact: 3, within_tolerance: 3, largest_deviation: BigDecimal("0"), day_count_convention: "actual_365" },
      reconciliation.summary)
  end

  # Measured against the alternative, so the oracle cannot pass on a fixture
  # whose offsets happen not to matter: without the offsets, no charge matches.
  test "the fixture's offsets move every charge" do
    without_offsets = Loan::StatementReconciliation.new(
      rows.map { |row| row.merge("offset" => "0.00") }.reject { |row| row["category"] == "offset_balance" }
    )

    without_offsets.charges.zip(reconciliation.charges).each do |gross, net|
      assert_operator gross.actual, :>, net.expected, "charge on #{net.date} must be reduced by its offsets"
    end
  end

  # The same charges, with the offsets read from an offset account's stored
  # daily balances through Loan::OffsetResolver -- the path production takes
  # (Loan::PayoffProjection on main; Loan::DailyInterest once #405 merges,
  # which hands the resolver's points to the same InterestAccrual call).
  test "every charge reconciles with the offsets resolved from stored balances" do
    loan = accounts(:loan).loan
    offset_account = loan.account.family.accounts.create!(
      name: "Reconciliation offset", balance: 0, currency: "USD", accountable: Depository.new
    )
    loan.loan_offset_accounts.create!(account: offset_account)
    rows.select { |row| row["category"] == "offset_balance" }.each do |row|
      offset_account.balances.create!(
        date: Date.iso8601(row["date"]), balance: row["offset"], start_cash_balance: row["offset"], currency: "USD"
      )
    end

    travel_to Date.new(2025, 6, 1) do
      resolver = Loan::OffsetResolver.new(loan)
      resolved = Loan::StatementReconciliation.new(rows, offset_for: resolver.method(:change_points))

      assert_equal reconciliation.charges.map(&:expected), resolved.charges.map(&:actual)
    end
  end

  test "a statement whose movements break its running balance is reported by row number only" do
    broken = rows.map(&:dup)
    broken[3]["balance"] = "-59000.01"

    problems = Loan::StatementReconciliation.new(broken).problems

    assert_equal [ "row 4: breaks the running balance", "row 5: breaks the running balance" ], problems
    assert problems.none? { |problem| problem.match?(/\d+\.\d{2}/) }, "a problem must not echo an amount"
  end

  test "an offset or rate move without its declaring row is reported" do
    undeclared = rows.map(&:dup)
    undeclared[3]["offset"] = "100.00"
    undeclared[3]["annual_rate"] = "7.00"

    problems = Loan::StatementReconciliation.new(undeclared).problems

    assert_includes problems, "row 4: moves the rate without a rate_change row"
    assert_includes problems, "row 4: moves the offset without an offset_balance row"
  end

  test "a charge that disagrees is counted and its deviation reported" do
    off_by_two_cents = rows.map(&:dup)
    second_charge = off_by_two_cents.index { |row| row["category"] == "interest" && row["date"] == "2025-03-06" }
    off_by_two_cents[second_charge]["amount"] = "-93.70"

    summary = Loan::StatementReconciliation.new(off_by_two_cents).summary

    assert_equal 3, summary[:compared]
    assert_equal 2, summary[:exact]
    assert_equal 2, summary[:within_tolerance]
    assert_equal BigDecimal("0.02"), summary[:largest_deviation]
  end

  test "the day-count basis is the caller's, not a constant" do
    actual_actual = Loan::StatementReconciliation.new(rows, day_count_convention: "actual_actual")

    assert_equal "actual_actual", actual_actual.summary[:day_count_convention]
    # 2025 is not a leap year, so the two bases agree on every 2025 window.
    assert_equal reconciliation.charges.map(&:actual), actual_actual.charges.map(&:actual)
  end

  test "a statement with the wrong headers is refused" do
    error = assert_raises(ArgumentError) { Loan::StatementReconciliation.from_csv("date,amount\n2025-01-06,1.00\n") }

    assert_includes error.message, Loan::StatementReconciliation::HEADERS.join(",")
  end

  private
    # One message per offending line: a date that is not ISO, a category
    # outside the allowlist, a column count other than six, or a numeric
    # column that is not a two-decimal number.
    def deidentification_violations(lines)
      lines.filter_map do |line|
        date, category, *numbers = line.split(",", -1)
        next "date" unless date.match?(/\A\d{4}-\d{2}-\d{2}\z/)
        next "category" unless Loan::StatementReconciliation::CATEGORIES.include?(category)
        next "columns" unless numbers.length == 4
        next "numeric" unless numbers.all? { |value| value.match?(/\A-?\d+\.\d{2}\z/) }
      end
    end

    def reconciliation
      @reconciliation ||= Loan::StatementReconciliation.from_csv(File.read(FIXTURE))
    end

    def rows
      @rows ||= CSV.parse(File.read(FIXTURE), headers: true).map(&:to_h)
    end
end
