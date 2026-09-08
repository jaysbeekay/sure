class Loan
  # Answers "what rate applies?" for a loan, without making Loan::Simulator
  # depend on the Loan model.
  #
  # A fixed loan answers the same rate for every date. A variable loan reads
  # its recorded rate changes.
  #
  # ## Why two questions, not one
  #
  # A rate change moves two different things on different days, and conflating
  # them bills the borrower wrongly:
  #
  #   * `accrual_rate_for(date)` -- the rate in force on a given day. The
  #     simulator asks this at each period's OPENING date, so a change takes
  #     effect from the period that begins on it.
  #   * `re_amortisation_events` -- the dates on which the contracted repayment
  #     is resized. The simulator applies these ON the payment date.
  #
  # Both read the same recorded changes; they are separate methods because the
  # simulator must be able to be told different answers. A rate that moves what
  # is charged without immediately moving what is owed each month is exactly
  # what a variable loan does between payment dates.
  class RateResolver
    def self.for(loan)
      new(loan)
    end

    def initialize(loan)
      @loan = loan
    end

    # The rate in force on `date`: the latest change effective on or before it,
    # falling back to the loan's own rate before any change applies.
    def accrual_rate_for(date)
      return loan.interest_rate unless loan.variable_rate_type?

      loan.current_variable_rate(date)
    end

    # Every recorded change falling inside [from_date, to_date], as the
    # {date:, rate:} pairs the simulator consumes. Bounds are inclusive at both
    # ends: a change effective on the final payment date still resizes it.
    def re_amortisation_events(from_date, to_date)
      return [] unless loan.variable_rate_type?

      loan.variable_rates.filter_map do |date, rate|
        effective_date = Date.iso8601(date.to_s)
        next unless effective_date >= from_date && effective_date <= to_date

        { date: effective_date, rate: rate }
      end
    end

    private
      attr_reader :loan
  end
end
