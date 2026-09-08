class Loan < ApplicationRecord
  include Accountable

  SUBTYPES = {
    "mortgage" => { short: "Mortgage", long: "Mortgage" },
    "student" => { short: "Student Loan", long: "Student Loan" },
    "auto" => { short: "Auto Loan", long: "Auto Loan" },
    "home_equity" => { short: "Home Equity", long: "Home Equity Loan" },
    "line_of_credit" => { short: "Line of Credit", long: "Line of Credit" },
    "business" => { short: "Business Loan", long: "Business Loan" },
    "other" => { short: "Other Loan", long: "Other Loan" }
  }.freeze

  # The rate types this calculator understands. A loan whose rate_type is
  # anything else -- including a value a provider supplied, since
  # PlaidAccount::Liabilities::MortgageProcessor writes Plaid's raw
  # `interest_rate.type` straight through -- is not amortizable, and gets the
  # same treatment it got before schedules existed: no schedule, no tab.
  FIXED_RATE_TYPE = "fixed".freeze
  VARIABLE_RATE_TYPES = %w[variable adjustable].freeze
  AMORTIZABLE_RATE_TYPES = ([ FIXED_RATE_TYPE ] + VARIABLE_RATE_TYPES).freeze

  validates :subtype, inclusion: { in: SUBTYPES.keys }, allow_blank: true

  # The contracted repayment, for a loan that has exactly one.
  #
  # Deliberately still nil for a variable loan even though it now has a
  # schedule: such a loan does not HAVE a single monthly payment, and quoting
  # the one it opened with would be a stale figure presented as a current one.
  # Answering it properly means re-amortising today's balance at today's rate,
  # which needs the projection this engine does not yet carry.
  def monthly_payment
    return nil if term_months.nil? || interest_rate.nil? || rate_type.nil? || rate_type != FIXED_RATE_TYPE
    # Non-positive, not just zero: `amortizable?` rejects both, so anything that
    # slips past here would fall through to a nil schedule instead of a payment.
    return Money.new(0, account.currency) if original_balance.amount <= 0 || term_months <= 0

    amortization_schedule&.periodic_payment
  end

  # A loan can be amortised once we know what was borrowed, at what rate, and
  # over how long.
  #
  # Variable loans are included. They were excluded while a schedule could only
  # be built off a single rate -- "a schedule built off today's rate would be
  # fiction" -- but the schedule now re-amortises at each recorded rate change,
  # so the objection no longer holds. A variable loan with no changes recorded
  # yet simply runs at its base rate, which is what it is actually doing.
  def amortizable?
    # `account` first: original_balance reads through it, and a Loan can exist
    # without one (Loan.new in a form, a fixture built in isolation). #2984's
    # `rate_type == "fixed"` guard happened to short-circuit before that read;
    # widening the rate types removed the accident, so the requirement is
    # stated rather than relied upon.
    account.present? &&
      AMORTIZABLE_RATE_TYPES.include?(rate_type) &&
      interest_rate.present? &&
      term_months.to_i.positive? &&
      original_balance.amount.positive?
  end

  # Whether this loan's rate can move over its life. The one place the answer
  # is defined -- callers must not compare rate_type to a string.
  def variable_rate_type?
    VARIABLE_RATE_TYPES.include?(rate_type)
  end

  # Recorded rate changes as [effective date string, rate] pairs, oldest first.
  def variable_rates
    (variable_rate_schedule || {}).sort_by { |date, _rate| Date.iso8601(date.to_s) }
  end

  # The rate in force on a given date: the latest change effective on or before
  # it, falling back to the loan's own rate before any change applies.
  def current_variable_rate(as_of = Date.current)
    return interest_rate unless variable_rate_type?

    rate = variable_rates.reverse.find { |date, _| Date.iso8601(date.to_s) <= as_of }&.last
    rate.nil? ? interest_rate : BigDecimal(rate.to_s)
  end

  # Assembles variable_rate_schedule from the form's rows.
  #
  # Keyed by effective date, so re-entering a date replaces that row rather
  # than adding a second one for the same day -- two rates in force on one date
  # is not a state the schedule can represent, and silently keeping both would
  # make which one wins depend on hash ordering.
  def rate_changes=(rows)
    self.variable_rate_schedule = Array(rows).each_with_object({}) do |row, acc|
      date = row[:effective_date].presence || row["effective_date"].presence
      rate = row[:rate].presence || row["rate"].presence
      next if date.blank? || rate.blank?

      acc[Date.parse(date.to_s).iso8601] = BigDecimal(rate.to_s).to_s("F")
    rescue ArgumentError, Date::Error
      next
    end
  end

  # Form rows, in a shape the form can render without parsing anything.
  def rate_change_rows
    variable_rates.map { |date, rate| { effective_date: date.to_s, rate: rate.to_s } }
  end

  def amortization_schedule
    @amortization_schedule ||= AmortizationSchedule.for(self)
  end

  # The date the loan was drawn down. Recorded explicitly when the borrower
  # knows it -- a loan is often drawn down before the account tracking it is
  # created -- and otherwise taken from the account's first valuation (the
  # opening balance), falling back to the opening anchor.
  def origination_date
    start_date || account.first_valuation&.date || account.opening_anchor_date
  end

  def original_balance
    Money.new(account.first_valuation_amount, account.currency)
  end

  class << self
    def color
      "#D444F1"
    end

    def icon
      "hand-coins"
    end

    def classification
      "liability"
    end
  end
end
