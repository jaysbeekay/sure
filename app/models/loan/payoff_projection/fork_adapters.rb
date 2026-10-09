class Loan
  class PayoffProjection
    # What the fork's projection does that upstream's does not (#184, direction
    # C), kept out of upstream's file so a sync merges the seams alone:
    #
    #   * interest charged through Loan::DailyInterest, as the schedule's is,
    #     plus the loan's offsets (#338) -- historical before `as_of`, today's
    #     total held flat after it (C16);
    #   * a loan behind schedule followed PAST the original maturity on the
    #     last level repayment, up to twice the term (#401), where upstream
    #     stops at maturity with a balloon;
    #   * `extra_payment:`, a hypothetical monthly extra on every period (the
    #     Extra repayments tab, #304), and the comparisons that tab quotes;
    #   * `scenario:`, a saved scenario's pinned rate, assumed offset and dated
    #     repayments (dormant: no UI);
    #   * `monthly_payment`, public: the repayment the projection opens on,
    #     which the retirement planner seeds from (#401's answer to #184's open
    #     question 1: the payment in force now).
    module ForkAdapters
      extend ActiveSupport::Concern

      # How far a loan behind schedule is followed, as a multiple of its term.
      MAX_ITERATIONS_MULTIPLIER = 2
      EXTRA_PAYMENT_FREQUENCIES = %w[weekly monthly yearly].freeze

      included do
        attr_reader :extra_payment
      end

      class_methods do
        # Converts a user-entered amount + cadence into the monthly-equivalent
        # Money an `extra_payment:` is modelled in. Returns nil for a blank,
        # zero, non-finite or non-numeric amount; raises on an unrecognised
        # frequency, which callers validate at the request boundary.
        def monthly_equivalent(amount:, frequency:, currency:)
          unless EXTRA_PAYMENT_FREQUENCIES.include?(frequency.to_s)
            raise ArgumentError, "unsupported frequency: #{frequency.inspect}"
          end

          return nil if amount.blank?

          parsed = begin
            BigDecimal(amount.to_s)
          rescue ArgumentError, TypeError
            nil
          end
          # finite? first: BigDecimal("NaN") and BigDecimal("Infinity") both
          # survive `parsed <= 0`, and either would poison the simulation.
          return nil if parsed.nil? || !parsed.finite? || parsed <= 0

          monthly_amount = case frequency.to_s
          when "weekly" then parsed * 52 / 12
          when "yearly" then parsed / 12
          else parsed
          end

          Money.new(monthly_amount, currency)
        end

        # Whether the Extra repayments tab is offered at all: coarser than
        # #applicable?, because a loan whose repayment barely covers its
        # interest is exactly the one someone wants to model paying more on.
        def eligible_for_extra_payment?(loan)
          loan.amortizable? && loan.account.balance.present? && loan.account.balance.positive?
        end
      end

      def payment_count
        payments.length
      end

      # The repayment the projection opens on, extra included: the contract's
      # repayment in force now. Nil when there is none to make.
      def monthly_payment
        return nil if contracted_payment.nil?

        Money.new(contracted_payment + extra_amount, currency)
      end

      # Whether this projection differs from the contract by enough to be
      # worth showing. A loan exactly on its contract projects the schedule
      # itself; one a cent or two behind settles in one tiny payment past
      # maturity, which is rounding rather than a real divergence -- so a
      # single period with less than one unit of interest at stake is not
      # shown.
      def diverges_from_schedule?
        return false unless converged?

        months_saved.abs > 1 || interest_saved.amount.abs >= 1
      end

      # What paying extra saves against `baseline` -- the same loan without
      # it. The Extra repayments tab's question, not #interest_saved's "where
      # am I against the contract?". Nil when either side never clears the
      # loan.
      def interest_saved_versus(baseline)
        return nil unless converged? && baseline.converged?

        baseline.total_interest.amount - total_interest.amount
      end

      def months_sooner_than(baseline)
        return nil unless converged? && baseline.converged?

        baseline.payment_count - payment_count
      end

      private
        # The dates the projection walks (#401): the contract's calendar from
        # the first payment after `as_of`, for twice the term -- to the
        # original maturity and as far again for a loan behind schedule -- and
        # never more than the simulator will walk. Past maturity the calendar
        # carries on as the schedule's does, a month at a time from
        # origination.
        def projected_payment_dates
          @projected_payment_dates ||= if schedule.nil?
            []
          else
            count = [ MAX_ITERATIONS_MULTIPLIER * schedule.term_months, Simulator::MAX_PERIODS ].min
            (first_calendar_index...(first_calendar_index + count)).map { |number| schedule.start_date >> number }
          end
        end

        # The calendar position of the first payment after `as_of`.
        def first_calendar_index
          @first_calendar_index ||= begin
            number = 1
            number += 1 while (schedule.start_date >> number) <= as_of
            number
          end
        end

        # The contract's repayment on `date`: the schedule's own row for that
        # date, as upstream pays it -- so a loan exactly on contract projects
        # the schedule itself, settlement included. Past maturity (#401) there
        # is no row, and a loan still owing pays the last LEVEL repayment: the
        # final row settles the schedule's own rounding, which is not a
        # repayment the contract asks of a loan in any other position.
        def level_payment_on(date)
          rows = schedule.payments
          return BigDecimal("0") if rows.empty?

          @rows_by_date ||= rows.index_by(&:date)
          row = @rows_by_date[date] || (rows.length > 1 ? rows[-2] : rows.last)
          row.payment.amount
        end

        def extra_amount
          extra_payment.present? ? extra_payment.amount : BigDecimal("0")
        end

        # The schedule's interest calculation plus the offsets and a
        # scenario's dated repayments, which only a projection from today's
        # balance has.
        def interest_calculation
          @interest_calculation ||= DailyInterest.for(
            loan, rate_resolver: rate_resolver, offset_for: offset_source, extra_for: repayment_source
          )
        end

        # The linked offsets, historical before `as_of` and today's total held
        # flat after it (C16). A scenario's assumed balance REPLACES them: the
        # question is "what if my offset held $X", not "$X on top".
        def offset_source
          assumed = assumed_offset_balance
          unless assumed.nil?
            return ->(from_date, to_date) { from_date >= to_date ? [] : [ { date: from_date, amount: assumed } ] }
          end

          OffsetResolver.new(loan, as_of: as_of).method(:change_points) if loan.countable_offset_accounts.exists?
        end

        # A scenario's dated repayments (C6), or nil without a scenario.
        def repayment_source
          return @repayment_source if defined?(@repayment_source)

          @repayment_source = @scenario && RepaymentPlan.for(@scenario, closes_on: projected_payment_dates.last)
            .method(:change_points)
        end

        # The principal a scenario's repayments pay in period `index` -- the
        # same dates the interest calculation sees for that period. Their
        # interest effect is charged from their own dates by DailyInterest;
        # their principal is paid with the period they fall in.
        def scenario_repayments_in(index)
          return BigDecimal("0") if repayment_source.nil?

          from_date = index.zero? ? current_period_start : projected_payment_dates[index - 1]
          to_date = projected_payment_dates[index]
          repayment_source.call(from_date, to_date)
            .select { |point| point[:date] >= from_date && point[:date] <= to_date }
            .sum(BigDecimal("0")) { |point| BigDecimal(point[:amount].to_s) }
        end

        # A scenario's pinned rate stands in for the loan's own, and pins its
        # changes away with it.
        def scenario_rate_resolver
          override = @scenario&.rate_override
          return nil if override.blank?

          FlatRateResolver.new(override)
        end

        def assumed_offset_balance
          value = @scenario&.assumed_offset_balance
          value.blank? ? nil : BigDecimal(value.to_s)
        end

        # A pinned rate applies on every date, so it never changes and never
        # re-amortises.
        class FlatRateResolver
          def initialize(rate)
            @rate = rate
          end

          def accrual_rate_for(_date) = @rate
          def re_amortisation_events(_from_date, _to_date) = []
        end
    end
  end
end
