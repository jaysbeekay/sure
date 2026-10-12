require "test_helper"

# #142 phase 2: reading a new rate out of a bank's transaction description.
#
# The wordings below are REPRESENTATIVE Australian bank phrasings written for
# these tests, not texts collected from real feeds -- the issue asked for real
# samples and none were gathered before this was built. When real ones turn up,
# add them here as they are.
class Loan::RateChangeTextTest < ActiveSupport::TestCase
  # --- Positive: the forms the rule exists to read ---------------------------

  test "a new-rate notice gives the new rate" do
    assert_rate "6.24", "INTEREST RATE CHANGE - NEW RATE 6.24% P.A."
  end

  test "a from-to notice gives the rate it changed TO, not the one it left" do
    assert_rate "6.24", "Your variable rate has changed from 6.49% to 6.24%"
  end

  test "a single percentage with no marker and no change wording is the rate" do
    assert_rate "6.24", "Variable rate 6.24% p.a."
  end

  test "a now-marker picks the rate after it" do
    assert_rate "6.24", "Variable rate was 6.49% and is now 6.24% p.a."
  end

  test "a changed-to notice carrying a date reads the percentage, not the date" do
    assert_rate "6.24", "VARIABLE RATE CHANGED TO 6.240% P.A. EFF 14/10/2026"
  end

  test "the same rate stated twice is one rate" do
    assert_rate "6.24", "Variable rate 6.24% (6.24% p.a.)"
  end

  test "the same rate stated twice, once after a marker, is one rate" do
    assert_rate "6.24", "NEW RATE 6.24% (6.24% P.A.)"
  end

  # --- Spelling of the percentage --------------------------------------------

  test "a space before the percent sign is accepted" do
    assert_rate "6.25", "New rate 6.25 %"
  end

  test "per cent spelled as two words is accepted" do
    assert_rate "6.25", "Your new interest rate is 6.250 per cent per annum"
  end

  test "percent spelled as one word is accepted" do
    assert_rate "6.25", "New interest rate 6.25 percent"
  end

  test "a whole-number rate is accepted" do
    assert_rate "6", "New rate 6%"
  end

  test "a rate is rounded to the three places the loan stores" do
    assert_rate "6.245", "New rate 6.2449%"
  end

  test "digits that are not followed by a percentage are not a rate" do
    assert_rate "6.24", "LOAN ACCT 123456789 NEW RATE 6.24%"
  end

  # --- Nothing to read: silent ------------------------------------------------

  test "text with no percentage gives nothing and no problem" do
    reading = Loan::RateChangeText.read("LOAN REPAYMENT")

    assert_nil reading.rate
    assert_nil reading.problem, "a description with no percentage is not a problem to report"
  end

  test "blank and nil text give nothing and no problem" do
    [ nil, "", "   " ].each do |text|
      reading = Loan::RateChangeText.read(text)
      assert_nil reading.rate, "#{text.inspect} gave a rate"
      assert_nil reading.problem, "#{text.inspect} reported a problem"
    end
  end

  # --- Ambiguity: nothing, and say so ----------------------------------------

  test "two different percentages with no marker are ambiguous" do
    reading = Loan::RateChangeText.read("Rate 6.25% comparison rate 6.40%")

    assert_nil reading.rate
    assert_equal :ambiguous, reading.problem
    assert_equal [ BigDecimal("6.25"), BigDecimal("6.4") ], reading.candidates
  end

  test "two different marked percentages are ambiguous" do
    reading = Loan::RateChangeText.read("Rate now 6.24% changing to 6.30%")

    assert_nil reading.rate
    assert_equal :ambiguous, reading.problem
  end

  # "by X%" is how much the rate moved, not what it is. Read as a rate, a cut of
  # a quarter point would record the loan at 0.25%.
  test "a change amount alone is not a rate" do
    reading = Loan::RateChangeText.read("Your variable rate decreased by 0.25%")

    assert_nil reading.rate
    assert_equal :change_amount_only, reading.problem
  end

  test "a signed percentage is a change amount, not a rate" do
    reading = Loan::RateChangeText.read("RATE ADJUSTMENT -0.25%")

    assert_nil reading.rate
    assert_equal :change_amount_only, reading.problem
  end

  # cubic, #400: a bare change verb, with no "by" or "of", still names how far
  # the rate moved. Read as a rate, "decreased 0.25%" would put the loan there.
  test "a percentage straight after a bare change verb is a change amount" do
    [ "Your variable rate decreased 0.25%", "Rate increased 0.5%", "Rate cut 0.25%",
      "Interest rate rose 0.25%", "Rate fell 0.25%", "Rate reduced 0.15%", "Rate down 0.25%" ].each do |text|
      reading = Loan::RateChangeText.read(text)

      assert_nil reading.rate, text
      assert_equal :change_amount_only, reading.problem, text
    end
  end

  # A comparative straight AFTER the percentage names a movement too. The
  # marker before it ("now") would otherwise make 0.25 the loan's rate.
  test "a percentage followed by a comparative is a change amount" do
    [ "Your variable rate is now 0.25% higher", "Rate now 0.25% lower", "Rate is 0.5% above the old rate",
      "Your rate is now 0.25% p.a. less", "Rate now 0.1 per cent more" ].each do |text|
      reading = Loan::RateChangeText.read(text)

      assert_nil reading.rate, text
      assert_equal :change_amount_only, reading.problem, text
    end
  end

  test "a comparative that does not follow the percentage leaves the rate alone" do
    assert_rate "6.24", "Rate now 6.24%, higher than last year"
    assert_rate "6.24", "Your new rate is 6.24%, 0.25% higher than before"
    assert_rate "6.24", "Rate now 6.24% p.a."
  end

  # Nightly review on #400: "Rate change 0.25%" reads as a new rate of 0.25%,
  # but a bank can mean a 0.25-point movement by it. With change wording and
  # no marker naming the new rate, the text cannot say which, so it is refused.
  test "change wording without a new-rate marker is refused" do
    [
      "Rate change 0.25%",
      "Rate change 6.24%",
      "RATE CHANGE 6.24%",
      "Interest rate changed 0.25%",
      "Your rate changes 0.25% from 1 November",
      "Rate adjustment 0.25%",
      "Variable rate adjusted 0.25% p.a."
    ].each do |text|
      reading = Loan::RateChangeText.read(text)

      assert_nil reading.rate, "#{text.inspect} gave a rate"
      assert_equal :change_wording, reading.problem, text
    end
  end

  test "change wording with a new-rate marker gives the marked rate" do
    assert_rate "6.24", "INTEREST RATE CHANGE - NEW RATE 6.24% P.A."
    assert_rate "6.24", "Rate change: now 6.24%"
    assert_rate "6.24", "Rate adjusted to 6.24% p.a."
  end

  test "a bare change verb beside the new rate gives the new rate" do
    assert_rate "6.24", "Rate decreased 0.25% to 6.24% p.a."
    assert_rate "6.24", "Rate cut to 6.24%"
  end

  test "a change amount beside the new rate gives the new rate" do
    assert_rate "6.24", "Rate decreased by 0.25% to 6.24% p.a."
  end

  # --- Range: both sides of each boundary ------------------------------------

  test "zero is out of range" do
    assert_out_of_range "New rate 0%"
  end

  test "a value that rounds to zero at three places is out of range" do
    assert_out_of_range "New rate 0.0004%"
  end

  test "the smallest value the loan stores is in range" do
    assert_rate "0.001", "New rate 0.001%"
  end

  test "just under one hundred is in range" do
    assert_rate "99.999", "New rate 99.999%"
  end

  test "a value that rounds to one hundred at three places is out of range" do
    assert_out_of_range "New rate 99.9996%"
  end

  test "one hundred is out of range" do
    assert_out_of_range "New rate 100%"
  end

  test "far above one hundred is out of range" do
    assert_out_of_range "NEW RATE 150% P.A."
  end

  # --- The convenience reader -------------------------------------------------

  test "parse returns the rate or nil" do
    assert_equal BigDecimal("6.24"), Loan::RateChangeText.parse("New rate 6.24%")
    assert_nil Loan::RateChangeText.parse("Rate change 0.25%")
    assert_nil Loan::RateChangeText.parse("Rate 6.25% comparison rate 6.40%")
    assert_nil Loan::RateChangeText.parse("LOAN REPAYMENT")
  end

  private
    def assert_rate(expected, text)
      reading = Loan::RateChangeText.read(text)

      assert_equal BigDecimal(expected), reading.rate, "read the wrong rate from #{text.inspect}"
      assert_nil reading.problem
    end

    def assert_out_of_range(text)
      reading = Loan::RateChangeText.read(text)

      assert_nil reading.rate, "#{text.inspect} gave a rate the loan cannot hold"
      assert_equal :out_of_range, reading.problem
    end
end
