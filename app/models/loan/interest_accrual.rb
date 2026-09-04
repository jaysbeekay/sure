class Loan
  # Calculates interest over a date range without rounding intermediate
  # segments. Dates are half-open: interest accrues for from_date up to, but
  # not including, to_date. An offset change is effective on its date.
  class InterestAccrual
    DAY_COUNT = BigDecimal("365")
    PERCENT = BigDecimal("100")

    def self.calculate(**args)
      new.calculate(**args)
    end

    def self.charge(currency_precision:, **args)
      calculate(**args).round(currency_precision)
    end

    def calculate(from_date:, to_date:, balance:, annual_rate:, annual_rate_changes: [], offset_changes: [])
      validate_dates!(from_date, to_date)

      principal = decimal(balance)
      rate = decimal(annual_rate)
      changes = normalize_changes(offset_changes, from_date, to_date)
      rate_changes = normalize_changes(annual_rate_changes, from_date, to_date)
      change_dates = (changes.map(&:first) + rate_changes.map(&:first) + [ from_date ]).uniq.sort
      offsets_by_date = changes.to_h
      rates_by_date = rate_changes.to_h
      current_offset = BigDecimal("0")
      current_rate = rate

      change_dates.each_with_index.sum do |segment_start, index|
        segment_end = change_dates[index + 1] || to_date
        days = (segment_end - segment_start).to_i
        current_offset = offsets_by_date[segment_start] if offsets_by_date.key?(segment_start)
        current_rate = rates_by_date[segment_start] if rates_by_date.key?(segment_start)
        next BigDecimal("0") if days.zero?

        interest_bearing_balance = [ principal - current_offset, BigDecimal("0") ].max
        interest_bearing_balance * days * current_rate / PERCENT / DAY_COUNT
      end
    end

    private

      def normalize_changes(changes, from_date, to_date)
        normalized = changes.filter_map do |change|
          date, amount = if change.is_a?(Array)
            change
          else
            [ change.fetch(:date), change.fetch(:amount) ]
          end
          next unless date >= from_date && date < to_date

          [ date, decimal(amount) ]
        end.sort_by(&:first)

        normalized.each_with_object([]) do |change, compacted|
          compacted << change unless compacted.last&.last == change.last
        end
      end

      def validate_dates!(from_date, to_date)
        return if from_date <= to_date

        raise ArgumentError, "accrual range must end on or after it starts"
      end

      def decimal(value)
        BigDecimal(value.to_s)
      rescue ArgumentError, TypeError
        raise ArgumentError, "accrual values must be numeric"
      end
  end
end
