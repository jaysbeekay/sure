class Loan
  # The fork's interest calculation, plugged into Loan::Simulator's interest
  # hook (#184, direction C). Upstream's simulator charges one period as one
  # twelfth of the opening rate on the opening balance; this charges it day by
  # day instead, which is what three fork features need:
  #
  #   * a day-count basis per loan -- actual/365, actual/actual, actual/360 and
  #     30/360 (Loan::InterestAccrual, #188, #284);
  #   * a rate change part-way through a period, charged from its own
  #     effective date rather than from the next period (#189, C7);
  #   * offset balances, which reduce the interest-bearing balance from the day
  #     they move (#338, C15, C16), and a scenario's dated extra repayments,
  #     which reduce it from the day they are paid (C6, dormant with scenarios).
  #
  # It returns the period's interest UNROUNDED; the simulator rounds the charge
  # once (C12, C13). It never moves the balance the simulator carries: an extra
  # repayment's principal reaches the run through the payment the projection
  # passes for that period (Loan::PayoffProjection), and this only charges
  # interest on the balance as it stood each day.
  #
  # On 30/360 with no change inside the period and no offset, the figure is
  # exactly upstream's twelfth of the rate, so such a loan schedules row for
  # row as upstream's engine does.
  class DailyInterest
    # C9: the order same-day events are applied in, executed rather than merely
    # declared. Payment and re-amortisation happen at the period boundary, which
    # the simulator owns; they are named here so an unhandled member raises.
    EVENT_ORDER = %i[accrual extra_repayment offset_movement payment re_amortisation].freeze

    attr_reader :day_count_convention

    # The calculation for `loan`'s contract: its own day-count basis and its
    # recorded rate changes. `rate_resolver` stands in for the loan's own (a
    # scenario's pinned rate), and `offset_for`/`extra_for` add the change
    # points a projection needs; the contracted schedule passes neither.
    def self.for(loan, rate_resolver: RateResolver.for(loan), offset_for: nil, extra_for: nil)
      new(
        day_count_convention: loan.day_count_convention,
        rate_changes: rate_resolver.method(:re_amortisation_events),
        offset_for: offset_for,
        extra_for: extra_for
      )
    end

    # Each source is a callable (from_date, to_date) -> change points:
    #   rate_changes  [{ date:, rate: }]   the rate in force from `date`
    #   offset_for    [{ date:, amount: }] the offset total from `date`
    #   extra_for     [{ date:, amount: }] a repayment made on `date`
    def initialize(day_count_convention:, rate_changes: nil, offset_for: nil, extra_for: nil)
      @day_count_convention = day_count_convention
      @rate_changes = rate_changes || ->(_from_date, _to_date) { [] }
      @offset_for = offset_for || ->(_from_date, _to_date) { [] }
      @extra_for = extra_for || ->(_from_date, _to_date) { [] }
    end

    # The interest on [from_date, to_date), opening on `balance` at
    # `annual_rate` -- Loan::Simulator's interest hook.
    def call(from_date:, to_date:, balance:, annual_rate:, **)
      InterestAccrual.calculate(
        from_date: from_date,
        to_date: to_date,
        balance: balance,
        annual_rate: annual_rate,
        change_points: change_points(from_date, to_date, balance, annual_rate),
        day_count_convention: day_count_convention
      )
    end

    private
      # Every date inside the window where the rate, the balance or the offset
      # moves, with what each is from that date. A change ON `from_date` applies
      # to the whole window and one ON `to_date` to none of it: the windows are
      # half-open (C10), so it belongs to the next one.
      def change_points(from_date, to_date, balance, annual_rate)
        extras = normalize(@extra_for.call(from_date, to_date), from_date, to_date)
        rates = normalize(@rate_changes.call(from_date, to_date), from_date, to_date)
        offsets = normalize(@offset_for.call(from_date, to_date), from_date, to_date)
        dates = ([ from_date ] + extras.keys + rates.keys + offsets.keys + [ to_date ]).uniq.sort

        current_balance = BigDecimal(balance.to_s)
        current_rate = BigDecimal(annual_rate.to_s)
        current_offset = BigDecimal("0")

        dates.filter_map do |date|
          EVENT_ORDER.each do |event|
            case event
            when :accrual
              current_rate = rates[date] if rates.key?(date)
            when :extra_repayment
              next unless extras.key?(date)

              current_balance = [ current_balance - extras[date], BigDecimal("0") ].max
            when :offset_movement
              current_offset = offsets[date] if offsets.key?(date)
            when :payment, :re_amortisation
              nil
            else
              raise ArgumentError, "unhandled event in EVENT_ORDER: #{event.inspect}"
            end
          end
          next if date == to_date

          { date: date, balance: current_balance, offset: current_offset, rate: current_rate }
        end
      end

      # {date => amount} for the changes inside [from_date, to_date]. A rate
      # change arrives as { date:, rate: }, the others as { date:, amount: }.
      def normalize(changes, from_date, to_date)
        Array(changes).each_with_object({}) do |change, normalized|
          date = change.fetch(:date)
          next unless date >= from_date && date <= to_date

          normalized[date] = BigDecimal(change.fetch(:rate) { change.fetch(:amount) }.to_s)
        end
      end
  end
end
