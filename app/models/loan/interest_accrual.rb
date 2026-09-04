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
      balance_days = principal * (to_date - from_date).to_i
      changes.each_with_index.sum do |(change_date, offset), index|
        segment_end = changes[index + 1]&.first || to_date
        days = (segment_end - change_date).to_i
        [ offset, principal ].min * days
      end.then { |offset_days| (balance_days - offset_days) * rate }
    end

    private

      def normalize_changes(changes, from_date, to_date)
        changes.filter_map do |change|
          date, amount = if change.is_a?(Array)
            change
          else
            [ change.fetch(:date), change.fetch(:amount) ]
          end
          next unless date >= from_date && date < to_date

          [ date, decimal(amount) ]
        end.sort_by(&:first)
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
