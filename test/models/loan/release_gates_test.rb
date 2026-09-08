require "test_helper"

# docs/loans/release-gates.md is the single authority on G1-G8. This asserts it
# is structurally usable as one.
#
# It exists because four documents disagreed about gate state at once, and the
# disagreement was only found by an outside review reading all four. A matrix
# that silently loses a gate, cites a file that has been moved, or records a
# gate as met with nothing behind it fails in exactly the way the four
# documents did -- quietly, and only where someone happens to look.
#
# What this CANNOT check is whether a state is true. Nothing mechanical can.
# What it can check is that every state is answerable: named once, evidenced,
# and pointing at artefacts that exist.
class Loan::ReleaseGatesTest < ActiveSupport::TestCase
  MATRIX = Rails.root.join("docs/loans/release-gates.md")
  GATES = %w[G1 G2a G2b G3 G4 G5 G6 G7 G8].freeze

  # A state that asserts a gate is met. These are the rows a release decision
  # would be made from, so these are the rows that must carry evidence.
  MET_STATES = /\*\*(Approved|Signed)\b/

  setup do
    lines = MATRIX.readlines
    @rows = lines.select { |line| line.match?(/^\| \*\*G\d/) }

    # Read the Evidence column's position from the header rather than hardcoding
    # it. A hardcoded index silently reads the wrong column the first time
    # someone inserts one, and the assertion it feeds -- "no gate is recorded as
    # met without evidence" -- would then pass on whatever happened to sit there
    # (Codacy, #95).
    header = lines.find { |line| line.include?("| Gate |") }
    @evidence_column = header.split("|").index { |cell| cell.strip == "Evidence" }
    assert @evidence_column, "the matrix must have an Evidence column for this file to check anything"
  end

  test "the matrix names every gate exactly once" do
    named = @rows.map { |row| row[/^\| \*\*(G\d[ab]?)\*\*/, 1] }

    assert_equal GATES, named,
      "every gate must appear exactly once, in order -- a matrix that drops G6 " \
      "reads as a complete picture with a gate missing from it"
  end

  test "every path the matrix cites exists" do
    # Backticks are a formatting choice, not the thing being checked. Every path
    # in the matrix today happens to be backticked -- Codacy's report that some
    # were not is wrong on the specifics -- but the check should not depend on
    # that: an evidence path written as plain prose would escape it entirely,
    # and the file would look guarded while its weakest citation was not.
    #
    # The trailing `[\w]` drops sentence punctuation, and the lookbehind stops a
    # match starting mid-path.
    cited = MATRIX.read.scan(%r{(?<![\w/])((?:docs|test|app|config|lib)/[\w/.-]*[\w])}).flatten.uniq
    assert_operator cited.length, :>, 5, "the matrix must cite its evidence by path, not by description"

    missing = cited.reject { |path| Rails.root.join(path).exist? }

    assert_empty missing,
      "the matrix cites paths that do not exist: #{missing.join(', ')} -- a moved " \
      "or deleted artefact silently turns evidence into a claim"
  end

  test "no gate is recorded as met without evidence" do
    met = @rows.select { |row| row.match?(MET_STATES) }
    assert_operator met.length, :>, 0, "this test proves nothing if no gate is recorded as met"

    met.each do |row|
      gate = row[/^\| \*\*(G\d[ab]?)\*\*/, 1]
      evidence = row.split("|")[@evidence_column].to_s.strip

      assert_not_equal "none", evidence.downcase,
        "#{gate} is recorded as met with no evidence"
      assert_operator evidence.length, :>, 20,
        "#{gate} is recorded as met but its evidence column says only #{evidence.inspect} -- " \
        "cite the artefact (process rule 3)"
    end
  end

  # The specific overstatement this programme has already made once, in three
  # documents at the same time. G2 was signed for the non-offset scope only;
  # "G2 is signed" without the qualifier claims offset accrual has been
  # reconciled against a real statement, which it has not.
  #
  # The first test already makes a bare `G2` row impossible. This pins the two
  # halves' content, so the split cannot be flattened back into one signed gate
  # by editing the rows rather than removing them.
  test "the two halves of G2 keep the scope that was actually signed" do
    signed = @rows.find { |row| row.start_with?("| **G2a**") }
    open_half = @rows.find { |row| row.start_with?("| **G2b**") }

    assert_match(/one lender, one loan/i, signed,
      "G2a's limits are the reason it cannot be reported as G2 -- they belong in the row")
    assert_match(/offset accrual explicitly excluded/i, signed,
      "the exclusion is the whole distinction between G2a and G2b")

    assert_match(/\*\*Open\*\*/, open_half, "G2b is not signed and must not read as though it were")
    assert_equal "none", open_half.split("|")[@evidence_column].to_s.strip.downcase,
      "G2b has no evidence, and an empty evidence column would let it drift into looking evidenced"
  end
end
