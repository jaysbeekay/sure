class Loan
  # Calculates interest over a date range without rounding intermediate
  # segments. Dates are half-open: interest accrues for from_date up to, but
  # not including, to_date. An offset change is effective on its date.
  class InterestAccrual
    DEFAULT_DAY_COUNT_CONVENTION = :actual_365
    DAY_COUNT_CONVENTIONS = %i[actual_365 actual_actual thirty_360 actual_360].freeze
    DAY_COUNT = BigDecimal("365")
    LEAP_YEAR_DAY_COUNT = BigDecimal("366")
    ACTUAL_360_DAY_COUNT = BigDecimal("360")
    PERCENT = BigDecimal("100")
    MONTHS_PER_YEAR = BigDecimal("12")
    DAYS_PER_30_360_MONTH = BigDecimal("30")

    def self.calculate(**args)
      new.calculate(**args)
    end

    def self.charge(currency_precision:, **args)
      calculate(**args).round(currency_precision)
    end

    def calculate(
      from_date:, to_date:, balance:, annual_rate:, annual_rate_changes: [], offset_changes: [],
      change_points: [], day_count_convention: DEFAULT_DAY_COUNT_CONVENTION
    )
      validate_dates!(from_date, to_date)
      day_count_convention = normalize_day_count_convention(day_count_convention)

      principal = decimal(balance)
      rate = decimal(annual_rate)
      points = normalize_change_points(change_points, from_date, to_date)
      points = legacy_change_points(offset_changes, annual_rate_changes, from_date, to_date) if points.empty?
      change_dates = calculation_dates(
        from_date: from_date,
        to_date: to_date,
        points: points,
        day_count_convention: day_count_convention
      )
      points_by_date = points.index_by { |point| point.fetch(:date) }
      current_balance = principal
      current_offset = BigDecimal("0")
      current_rate = rate

      change_dates.each_with_index.sum do |segment_start, index|
        segment_end = change_dates[index + 1] || to_date
        days = (segment_end - segment_start).to_i
        if (point = points_by_date[segment_start])
          current_balance = point.fetch(:balance, current_balance)
          current_offset = point.fetch(:offset, current_offset)
          current_rate = point.fetch(:rate, current_rate)
        end
        next BigDecimal("0") if days.zero?

        interest_bearing_balance = [ current_balance - current_offset, BigDecimal("0") ].max
        if day_count_convention == :thirty_360
          next thirty_360_interest(interest_bearing_balance, current_rate, days, from_date, to_date)
        end

        interest_bearing_balance * days * current_rate / PERCENT /
          day_count_denominator(segment_start, day_count_convention)
      end
    end

    private

      # 30/360 (#188): upstream's flat 1/12, on this daily engine. The accrual
      # range is one scheduled period (Loan::Simulator asks once per payment),
      # and a period that is one calendar-month step on the schedule's anchor
      # day -- clamped into a short month and recovered after it, as upstream's
      # `origination >> n` calendar pays (#184) -- is one month of 30 days, so
      # it charges exactly a twelfth of the annual rate whatever its calendar
      # length. That keeps a 30/360 schedule equal row for row to upstream's
      # flat-twelfth engine.
      #
      # Any other range (the payoff projection's first stub from `as_of`)
      # counts 30E/360 days. A change part-way through splits the period's
      # months by elapsed actual days, since 30/360 does not say where inside
      # a month a day falls.
      #
      # The twelfth is computed as (rate / 100) / 12, the order the monthly
      # path uses, so a full period is the same BigDecimal and rounds alike.
      def thirty_360_interest(balance, annual_rate, days, from_date, to_date)
        monthly = (annual_rate / PERCENT) / MONTHS_PER_YEAR
        months = thirty_360_months(from_date, to_date)
        period_days = (to_date - from_date).to_i
        return balance * monthly * months if days == period_days

        balance * monthly * months * days / period_days
      end

      def thirty_360_months(from_date, to_date)
        return BigDecimal("1") if calendar_month_step?(from_date, to_date)

        days = (to_date.year - from_date.year) * 360 + (to_date.month - from_date.month) * 30 +
          [ to_date.day, 30 ].min - [ from_date.day, 30 ].min
        BigDecimal(days.to_s) / DAYS_PER_30_360_MONTH
      end

      # Whether [from_date, to_date) is one month on some anchor day: the next
      # calendar month, on the same day clamped to that month's length. A
      # `from_date` on a month end may itself be a clamp (28 February for an
      # anchor on the 31st), so from there any later day up to the next
      # month's end is the anchor recovered.
      def calendar_month_step?(from_date, to_date)
        return false unless (to_date.year * 12 + to_date.month) - (from_date.year * 12 + from_date.month) == 1

        days_in_to_month = Time.days_in_month(to_date.month, to_date.year)
        floor = [ from_date.day, days_in_to_month ].min
        return to_date.day == floor unless from_date == from_date.end_of_month

        to_date.day >= floor
      end

      def legacy_change_points(offset_changes, annual_rate_changes, from_date, to_date)
        offsets = normalize_changes(offset_changes, from_date, to_date).to_h
        rates = normalize_changes(annual_rate_changes, from_date, to_date).to_h
        (offsets.keys | rates.keys).sort.map do |date|
          { date: date, offset: offsets[date], rate: rates[date] }.compact
        end
      end

      def normalize_change_points(points, from_date, to_date)
        Array(points).filter_map do |point|
          next unless point.fetch(:date) >= from_date && point.fetch(:date) < to_date

          {
            date: point.fetch(:date),
            balance: point[:balance] && decimal(point[:balance]),
            offset: point[:offset] && decimal(point[:offset]),
            rate: point[:rate] && decimal(point[:rate])
          }.compact
        end.sort_by { |point| point.fetch(:date) }
      end

      def normalize_changes(changes, from_date, to_date)
        normalized = Array(changes).filter_map do |change|
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

      def calculation_dates(from_date:, to_date:, points:, day_count_convention:)
        dates = [ from_date ] + points.map { |point| point.fetch(:date) }
        if day_count_convention == :actual_actual
          dates.concat((from_date.year + 1...to_date.year + 1).map { |year| Date.new(year, 1, 1) })
        end
        dates.push(to_date).uniq.select { |date| date <= to_date }.sort
      end

      # One explicit branch per basis. Before #284 anything other than
      # actual/actual fell through to 365, so a basis added to the list without
      # a branch here would have accrued silently as actual/365; now it raises.
      # (30/360 never reaches this: it returns early above.)
      def day_count_denominator(date, day_count_convention)
        case day_count_convention
        when :actual_365 then DAY_COUNT
        when :actual_actual then Date.leap?(date.year) ? LEAP_YEAR_DAY_COUNT : DAY_COUNT
        when :actual_360 then ACTUAL_360_DAY_COUNT
        else
          raise ArgumentError, "no day-count denominator for #{day_count_convention.inspect}"
        end
      end

      def normalize_day_count_convention(value)
        convention = value.to_sym
        return convention if DAY_COUNT_CONVENTIONS.include?(convention)

        raise ArgumentError,
          "unsupported day-count convention: #{value.inspect} (expected one of #{DAY_COUNT_CONVENTIONS.join(', ')})"
      rescue NoMethodError
        raise ArgumentError, "unsupported day-count convention: #{value.inspect}"
      end

      def decimal(value)
        BigDecimal(value.to_s)
      rescue ArgumentError, TypeError
        raise ArgumentError, "accrual values must be numeric"
      end
  end
end
