# frozen_string_literal: true

# Reads a loan's new interest rate out of free text: a bank transaction's
# description or the notes on it (#142, phase 2). Pure -- it reads a string and
# answers, and writes nothing.
#
# WHAT IT ACCEPTS IS A DESIGN DECISION, NOT A SURVEY. The issue asked for real
# description texts to be collected from several banks before this was built,
# and none were. The forms below are representative Australian wordings, chosen
# so that every one of them is either read correctly or refused; they are not a
# record of what any bank actually sends. Widen them from real samples, not from
# guesses.
#
# - A percentage is a number followed by `%`, `per cent` or `percent`, with or
#   without a space ("6.24%", "6.24 %", "6.250 per cent").
# - A percentage straight after a marker -- "to", "now", "new rate", "new
#   interest rate", optionally followed by "is"/"of" and a colon -- is the new
#   rate. "changed from 6.49% to 6.24%" gives 6.24.
# - Without a marker, the text must hold exactly ONE distinct percentage.
#   "Rate 6.25% comparison rate 6.40%" is refused as ambiguous rather than
#   guessed at: a wrong rate silently re-prices every period after it.
# - A percentage after "by", "increase of", "cut of" and the like, or carrying a
#   sign ("-0.25%"), is how far the rate MOVED, never what it is. Read as a
#   rate, a quarter-point cut would put the loan at 0.25%.
# - The rate is rounded to three places, which is what the loan stores
#   (Loan#quantize_variable_rate_schedule), and must then be above 0 and below
#   100. A rate the loan's own validation would accept at exactly 0 or 100 is
#   still refused here: neither is a plausible reading of a rate-change notice,
#   and both are what a mis-read of an unrelated figure tends to produce.
class Loan::RateChangeText
  # `problem` is nil when the text simply holds no percentage -- the ordinary
  # case for a description that is not a rate notice, and nothing to report.
  # Otherwise it names why a percentage that IS there was not used:
  # `:ambiguous`, `:out_of_range` or `:change_amount_only`.
  Reading = Data.define(:rate, :problem, :candidates)

  NONE = Reading.new(rate: nil, problem: nil, candidates: []).freeze

  PRECISION = 3

  # The number may carry a sign, which marks it as a change amount. The
  # lookbehind stops "12345.6%" being read from its tail and keeps a digit run
  # such as an account number from lending its last digits to a percentage.
  PERCENTAGE = /(?<![\d.])(?<sign>[+-])?(?<number>\d+(?:\.\d+)?|\.\d+)\s*(?:%|per\s*cent\b)/i

  # What, immediately before a percentage, makes it the new rate.
  NEW_RATE_MARKER = /(?:\bto|\bnow|\bnew\s+(?:interest\s+)?rate(?:\s+(?:is|of))?)\s*:?\s*\z/i

  # What, immediately before a percentage, makes it a change amount.
  CHANGE_MARKER = /(?:\bby|\b(?:increase|increased|decrease|decreased|rise|cut|reduction|change)\s+of)\s*:?\s*\z/i

  def self.read(text)
    new(text).reading
  end

  def self.parse(text)
    read(text).rate
  end

  def initialize(text)
    @text = text.to_s
  end

  def reading
    return NONE if percentages.empty?

    rates = percentages.reject { |p| p[:change] }
    return refuse(:change_amount_only, percentages) if rates.empty?

    marked = rates.select { |p| p[:marked] }
    chosen = (marked.presence || rates).map { |p| p[:value] }.uniq
    return refuse(:ambiguous, rates) if chosen.size > 1

    rate = chosen.first
    return refuse(:out_of_range, rates) unless rate.positive? && rate < 100

    Reading.new(rate: rate, problem: nil, candidates: rates.map { |p| p[:value] }.uniq)
  end

  private
    attr_reader :text

    def refuse(problem, found)
      Reading.new(rate: nil, problem: problem, candidates: found.map { |p| p[:value] }.uniq)
    end

    def percentages
      @percentages ||= text.to_enum(:scan, PERCENTAGE).map do
        match = Regexp.last_match
        before = text[0...match.begin(0)]

        {
          value: BigDecimal(match[:number]).round(PRECISION),
          change: match[:sign].present? || before.match?(CHANGE_MARKER),
          marked: before.match?(NEW_RATE_MARKER)
        }
      end
    end
end
