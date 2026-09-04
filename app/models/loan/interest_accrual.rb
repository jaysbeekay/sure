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

    def calculate(from_date:, to_date:, balance:, annual_rate:, offset_changes: [])
      validate_dates!(from_date, to_date)

      principal = decimal(balance)
      rate = decimal(annual_rate) / PERCENT / DAY_COUNT
      changes = normalize_changes(offset_changes, from_date, to_date)
      boundaries = [ from_date, *changes.map(&:first), to_date ].uniq.sort

      boundaries.each_cons(2).sum do |segment_start, segment_end|
        days = BigDecimal((segment_end - segment_start).to_i.to_s)
        offset = changes.reverse_each.find { |date, _amount| date <= segment_start }&.last || BigDecimal("0")
        interest_bearing_balance = [ principal - offset, BigDecimal("0") ].max
        (days * interest_bearing_balance * rate).to_d
      end
    end

    private

      def normalize_changes(changes, from_date, to_date)
        changes.map do |change|
          date = change.fetch(:date)
          amount = decimal(change.fetch(:amount))
          [ date, amount ]
        end.select { |date, _amount| date >= from_date && date < to_date }.sort_by(&:first)
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
