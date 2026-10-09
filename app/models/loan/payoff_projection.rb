class Loan
  # Where the loan is actually heading, starting from today's real balance
  # rather than from the contract.
  #
  # The contracted schedule answers "what did you agree to?". This answers "what
  # is going to happen?", and the gap between them is the whole point: a
  # borrower who has overpaid is ahead of the schedule, one whose balance has
  # grown is behind, and neither is visible from the contract alone.
  #
  # It pays the repayment the CONTRACT requires in each period -- the
  # schedule's own row, re-amortised wherever the schedule re-amortises --
  # against a balance that is no longer the contracted one. That is deliberate:
  # re-sizing the repayment to today's balance would answer a different and much
  # less useful question, and would land every borrower who is ahead back on
  # the original maturity. Paying what the contract asks against a smaller
  # balance is how they finish sooner.
  #
  # Extra payments the borrower has already made are in here without being
  # named: they are why today's balance is what it is.
  #
  # ## Fork divergences (#184, direction C)
  #
  #   * Interest is charged through Loan::DailyInterest, as the schedule's is,
  #     plus the loan's offset balances (#338) -- historical before `as_of`,
  #     today's total held flat after it (C16).
  #   * A loan behind schedule is followed PAST the original maturity on the
  #     last level repayment, up to twice the term (#401), instead of stopping
  #     at maturity with a balloon. The schedule's final row settles its own
  #     rounding; it is not a repayment the contract asks of a loan in any other
  #     position, so no period past maturity is paid as such.
  #   * `extra_payment:` rides a hypothetical monthly extra on every period --
  #     the Extra repayments tab (#304) -- and `scenario:` applies a saved
  #     scenario's rate, offset and dated repayments (dormant: no UI).
  #   * `monthly_payment` is public: the repayment this projection opens on,
  #     which the retirement planner seeds from (#401's answer to #184's open
  #     question 1: the payment in force now).
  class PayoffProjection
    # How far a loan behind schedule is followed, as a multiple of its term.
    MAX_ITERATIONS_MULTIPLIER = 2
    EXTRA_PAYMENT_FREQUENCIES = %w[weekly monthly yearly].freeze

    attr_reader :loan, :as_of, :extra_payment

    def initialize(loan, as_of: Date.current, extra_payment: nil, scenario: nil)
      @loan = loan
      @as_of = as_of
      @extra_payment = extra_payment
      @scenario = scenario
    end

    # Converts a user-entered amount + cadence into the monthly-equivalent
    # Money an `extra_payment:` is modelled in. Returns nil for a blank, zero,
    # non-finite or non-numeric amount; raises on an unrecognised frequency,
    # which callers validate at the request boundary.
    def self.monthly_equivalent(amount:, frequency:, currency:)
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
    # #applicable?, because a loan whose repayment barely covers its interest is
    # exactly the one someone wants to model paying more on.
    def self.eligible_for_extra_payment?(loan)
      loan.amortizable? && loan.account.balance.present? && loan.account.balance.positive?
    end

    # False when there is nothing to project: no schedule, nothing left to owe,
    # no payments remaining, or no repayment to hold.
    #
    # `&&` binds tighter than `||`, so the trailing `|| false` applies to the
    # whole chain. It turns the nil that `contracted_payment&.positive?` gives for
    # a missing payment into false, so callers always get a boolean.
    #
    # Applicable is not converged: a projection that runs but never clears the
    # balance is applicable, and #converged? says so.
    def applicable?
      schedule.present? &&
        current_balance.amount.positive? &&
        projected_payment_dates.any? &&
        contracted_payment&.positive? || false
    end

    def currency
      loan.account.currency
    end

    # `accounts.balance` is nullable, and Money.new(nil) raises. A loan with no
    # balance yet has nothing to project, so it reads as zero: applicable? is
    # then false and the Schedule tab's card says so instead of the page failing.
    def current_balance
      @current_balance ||= Money.new(loan.account.balance || 0, currency)
    end

    def payments
      simulation&.payments || []
    end

    def payment_count
      payments.length
    end

    def payoff_date
      simulation&.payoff_date
    end

    def total_interest
      Money.new(simulation&.total_interest || 0, currency)
    end

    # False when the repayment does not clear the balance within the window --
    # the original maturity and, for a loan behind schedule, as far again past
    # it. There is no payoff date in that case.
    def converged?
      simulation ? simulation.converged? : false
    end

    def balloon_amount
      Money.new(simulation&.balloon_amount || 0, currency)
    end

    # The repayment the projection opens on, extra included: the contract's
    # repayment in force now. Nil when there is none to make.
    def monthly_payment
      return nil if contracted_payment.nil?

      Money.new(contracted_payment + extra_amount, currency)
    end

    # Positive means the loan finishes earlier than the contract said. Zero for
    # a run that never clears the balance, which has no finish to compare.
    def months_saved
      return 0 unless converged?

      remaining_payment_dates.length - payments.length
    end

    # Positive means less interest than the contract's remaining interest.
    def interest_saved
      return Money.new(0, currency) unless converged?

      Money.new(remaining_contracted_interest - (simulation&.total_interest || 0), currency)
    end

    # Whether this projection differs from the contract by enough to be worth
    # showing. A loan exactly on its contract projects the schedule itself; one
    # a cent or two behind settles in one tiny payment past maturity, which is
    # rounding rather than a real divergence -- so a single period with less
    # than one unit of interest at stake is not shown.
    def diverges_from_schedule?
      return false unless converged?

      months_saved.abs > 1 || interest_saved.amount.abs >= 1
    end

    # What paying extra saves against `baseline` -- the same loan without it.
    # The Extra repayments tab's question, not #interest_saved's "where am I
    # against the contract?". Nil when either side never clears the loan.
    def interest_saved_versus(baseline)
      return nil unless converged? && baseline.converged?

      baseline.total_interest.amount - total_interest.amount
    end

    def months_sooner_than(baseline)
      return nil unless converged? && baseline.converged?

      baseline.payment_count - payment_count
    end

    private
      def schedule
        @schedule ||= loan.amortization_schedule
      end

      # The contract's rows still ahead, in order.
      def remaining_scheduled_payments
        @remaining_scheduled_payments ||= (schedule&.payments || [])
          .select { |payment| payment.date > as_of }
      end

      # The contract's payment dates still ahead: what #months_saved counts
      # against.
      def remaining_payment_dates
        @remaining_payment_dates ||= remaining_scheduled_payments.map(&:date)
      end

      # The dates the projection walks (fork, #401): the contract's calendar
      # from the first payment after `as_of`, for twice the term -- to the
      # original maturity and as far again for a loan behind schedule -- and
      # never more than the simulator will walk. Past maturity the calendar
      # carries on as the schedule's does, a month at a time from origination.
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

      # The repayment in force: the contract's repayment for the first
      # projected date.
      def contracted_payment
        return @contracted_payment if defined?(@contracted_payment)

        @contracted_payment = projected_payment_dates.first && level_payment_on(projected_payment_dates.first)
      end

      # What the contract asks for in the projection's period `index`, plus the
      # modelled extra and any of a scenario's repayments falling in the
      # period: a dated repayment's interest effect is charged from its own
      # date by the interest calculation, and its principal is paid here, with
      # the period it falls in.
      def scheduled_payment_for(index:, **)
        level_payment_on(projected_payment_dates[index]) + extra_amount + scenario_repayments_in(index)
      end

      # The contract's repayment on `date`: the schedule's own row for that
      # date, as upstream pays it -- so a loan exactly on contract projects the
      # schedule itself, settlement included. Past maturity (fork, #401) there
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

      def remaining_contracted_interest
        remaining_scheduled_payments.sum(BigDecimal("0")) { |payment| payment.interest.amount }
      end

      # The date the period containing `as_of` opened: the last payment date on
      # the contract's calendar on or before it, or origination before the
      # first. The simulator charges a period at the rate in force when it
      # OPENED, so the projection's first period opens where the schedule's
      # does. Opened at `as_of`, a rate change recorded between the last payment
      # and today re-rated a month the schedule charges at the old rate, and a
      # borrower exactly on contract was quoted interest they will never pay.
      def current_period_start
        schedule.start_date >> (first_calendar_index - 1)
      end

      def simulation
        return nil unless applicable?

        @simulation ||= Simulator.new(
          starting_balance: current_balance.amount,
          accrual_start_date: current_period_start,
          payment_schedule: projected_payment_dates,
          accrual_rate_for: rate_resolver.method(:accrual_rate_for),
          re_amortisation_events: rate_resolver.method(:re_amortisation_events),
          # The contract's own repayment, period by period. Not :reamortize:
          # that re-sizes off the balance in front of it, and for a borrower
          # who is ahead that shrinks the repayment until the loan lands back
          # on the original maturity -- the opposite of what paying the
          # contracted amount against a smaller balance actually does. On a
          # fixed loan every row carries the same figure, so this is the held
          # contracted payment; on a variable loan it moves exactly where the
          # schedule's does.
          payment_amount: method(:scheduled_payment_for),
          payment_strategy: :scheduled,
          currency_precision: currency_precision,
          # A projection that cannot clear the balance must SAY so. Settling the
          # final payment regardless would manufacture a payoff date for a loan
          # the contract no longer pays off.
          settle_at_schedule_end: false,
          interest_for: interest_calculation
        ).run
      end

      # A scenario's pinned rate stands in for the loan's own, and pins its
      # changes away with it.
      def rate_resolver
        @rate_resolver ||= scenario_rate_resolver || RateResolver.for(loan)
      end

      # Fork: the schedule's interest calculation plus the offsets and a
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

      # The principal a scenario's repayments pay in period `index` -- the same
      # dates the interest calculation sees for that period.
      def scenario_repayments_in(index)
        return BigDecimal("0") if repayment_source.nil?

        from_date = index.zero? ? current_period_start : projected_payment_dates[index - 1]
        to_date = projected_payment_dates[index]
        repayment_source.call(from_date, to_date)
          .select { |point| point[:date] >= from_date && point[:date] <= to_date }
          .sum(BigDecimal("0")) { |point| BigDecimal(point[:amount].to_s) }
      end

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

      def currency_precision
        @currency_precision ||= Money::Currency.new(currency).default_precision || 2
      end
  end
end
