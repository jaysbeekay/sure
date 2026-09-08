class Loan
  # Materialises a regular extra repayment into the per-date amounts the
  # simulator consumes.
  #
  # Recurrence resolution is DELEGATED to RecurringTransaction::Schedule, whose
  # constructor takes plain keywords and needs no RecurringTransaction. There is
  # no second recurrence engine here and there should not be one.
  #
  # Exact dates, never a monthly equivalent: $500 weekly is 52 balance
  # reductions a year, not 12 of $2,166.67, and the interest difference between
  # those two is the entire reason someone models a weekly repayment.
  class RepaymentPlan
    # Cadences offered, expressed in terms the shared schedule already
    # understands.
    FREQUENCY_RULES = {
      "weekly" => { frequency: "weekly", interval: 1 },
      "monthly" => { frequency: "monthly", interval: 1 }
    }.freeze

    FREQUENCIES = FREQUENCY_RULES.keys.freeze

    attr_reader :amount, :frequency, :starts_on, :closes_on

    # `closes_on` is the last payment date the caller will walk. The final
    # window is closed at its end; every other window is half-open. Without it a
    # repayment dated on the final payment date falls in NO window and is
    # silently dropped.
    def initialize(amount:, frequency:, starts_on:, closes_on: nil)
      @amount = BigDecimal(amount.to_s)
      @frequency = frequency.to_s
      @starts_on = starts_on
      @closes_on = closes_on
    end

    def valid?
      amount.positive? && FREQUENCY_RULES.key?(frequency) && starts_on.present?
    end

    # Change points in [from_date, to_date) -- HALF-OPEN, deliberately -- except
    # for the final window, which is closed.
    #
    # The simulator walks contiguous periods and asks each for its changes,
    # matching dates inclusively at both ends. A repayment landing exactly on a
    # payment date would therefore be handed to the period that CLOSES on it and
    # the period that OPENS on it, and applied twice -- on a 24-payment loan,
    # one $5,000 repayment on a payment date reduced principal by $10,000.
    #
    # Excluding the closing boundary puts each date in exactly one period: the
    # one that opens on it. The exception is the LAST window, which has no
    # successor to open on the final payment date, so a repayment there would
    # fall through every window and vanish. That window alone closes inclusively.
    def change_points(from_date, to_date)
      return [] unless valid?
      return [] if from_date.nil? || to_date.nil? || from_date >= to_date

      upper = (closes_on.present? && to_date >= closes_on) ? to_date : to_date - 1
      window_start = [ from_date, starts_on ].max
      return [] if window_start > upper

      schedule.occurrences_between(window_start, upper)
        .map { |date| { date: date, amount: amount } }
    end

    private
      # The anchor is the plan's OWN start date, never the window's. Anchoring
      # on the window re-anchors the recurrence on every call -- and the
      # projection calls this once per payment period, so a monthly repayment
      # would fire on a different day of the month in every one of them.
      def schedule
        @schedule ||= begin
          rule = FREQUENCY_RULES.fetch(frequency)

          RecurringTransaction::Schedule.new(
            expected_day_of_month: starts_on.day,
            rules: [
              RecurringTransaction::Schedule::Rule.new(
                frequency: rule.fetch(:frequency),
                interval: rule.fetch(:interval),
                # Monthly resolves a day within a month; weekly uses a weekday.
                day_of_month: rule.fetch(:frequency) == "weekly" ? nil : starts_on.day,
                weekday: rule.fetch(:frequency) == "weekly" ? starts_on.wday : nil,
                weekday_ordinal: nil,
                month_of_year: nil
              )
            ],
            anchor_date: starts_on,
            weekend_adjust: "none"
          )
        end
      end
  end
end
