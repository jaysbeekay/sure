class Loan
  # Projects a loan's payoff from its *current actual balance* rather than
  # its original contracted balance -- so a user who has made extra
  # principal payments sees a sooner payoff date and the interest they
  # saved, instead of the static original-terms schedule from
  # AmortizationSchedule.
  #
  # Deliberately keeps the ORIGINAL schedule's monthly payment amount fixed
  # and simulates forward from today's balance, rather than re-amortizing
  # the remaining term at the current balance. Re-amortizing would *lower*
  # the payment to fit the remaining term; what we want is "same payment,
  # paid off sooner" -- the real-world effect of an extra/lump-sum payment.
  #
  # Not persisted: computed live from loan.account.balance on every call, so
  # it's automatically current after every sync or manual balance update.
  #
  # Caveat: treats account.balance as principal-only (same assumption
  # AmortizationSchedule makes about original_balance). A provider-synced
  # balance that includes escrow will understate interest/time saved.
  class PayoffProjection
    MAX_ITERATIONS_MULTIPLIER = 2

    attr_reader :loan

    def initialize(loan)
      @loan = loan
    end

    def currency
      @currency ||= loan.account.currency
    end

    # Loans with a real payment amount and a positive
    # current balance are eligible -- and only when there's actually
    # something to project (the original schedule must be amortizable) AND
    # the simulation actually converges to zero within the iteration cap
    # (see #converged? -- a payment that technically covers interest but
    # would take an implausibly long time is treated as not applicable
    # rather than silently reporting a truncated, non-payoff "payoff date").
    def applicable?
      loan.amortization_schedule.amortizable? &&
        original_schedule_rows.any? &&
        monthly_payment.present? && monthly_payment.amount.positive? &&
        current_balance.amount.positive? &&
        !unamortizable_payment? &&
        converged?
    end

    def current_balance
      Money.new(loan.account.balance, currency)
    end

    def monthly_payment
      loan.amortization_schedule.monthly_payment
    end

    # The simulated forward schedule from today until the balance is paid off.
    def payments
      return [] unless applicable?
      raw_schedule
    end

    def payment_count
      payments.length
    end

    # Reports whether the raw simulation reaches an exact zero balance within
    # its bounded horizon, independently of whether the result is displayable.
    def converged?
      schedule = raw_schedule
      schedule.present? && schedule.last[:ending_balance].zero?
    end

    def payoff_date
      return nil if payments.empty?
      payments.last[:payment_date]
    end

    def total_interest
      return Money.new(0, currency) if payments.empty?
      Money.new(payments.sum { |p| p[:interest_payment] }, currency)
    end

    # How many fewer payments this projection takes versus the original
    # schedule's remaining payments as of today. Positive means ahead of
    # schedule (paid off sooner); negative means behind.
    def months_saved
      return nil unless applicable?
      original_remaining_payment_count - payment_count
    end

    # How much less interest this projection pays versus the original
    # schedule's remaining interest as of today. Positive means savings;
    # negative means more interest will be paid (behind schedule).
    # This compares against the *next scheduled payment date* boundary, not
    # a true daily accrual -- consistent with the rest of the amortization
    # feature, which has no daily-accrual concept anywhere.
    def interest_saved
      return nil unless applicable?
      (original_remaining_interest - total_interest.amount)
    end

    private

      def unamortizable_payment?
        rate = Loan::RateResolver.for(loan).accrual_rate_for(first_projected_payment_date)
        monthly_rate = (BigDecimal(rate.to_s) / BigDecimal("100")) / BigDecimal("12")
        return false if monthly_rate.zero?

        first_interest = current_balance.amount * monthly_rate
        monthly_payment.amount <= first_interest
      end

      # The contracted schedule this projection is compared against.
      #
      # Read through AmortizationSchedule#display_rows rather than
      # loan.amortizations directly, so the projection uses the same rows the
      # table and the summary cards show. The persisted rows are used when they
      # are current; when they are stale the schedule recomputes them in memory.
      #
      # This used to read loan.amortizations and required rows to exist, which
      # silently disabled the projection whenever the persisted schedule was
      # missing -- previously masked because the Schedule tab rebuilt it inside
      # the request. It no longer does (#39), so a display calculation must not
      # depend on a write having happened.
      def original_schedule_rows
        @original_schedule_rows ||= loan.amortization_schedule.display_rows
      end

      def original_remaining_payments
        @original_remaining_payments ||= original_schedule_rows.select do |row|
          row.payment_date > Date.current
        end
      end

      def first_projected_payment_date
        original_remaining_payments.first&.payment_date || Date.current.next_month
      end

      def original_remaining_payment_count
        original_remaining_payments.count
      end

      def original_remaining_interest
        original_remaining_payments.sum(BigDecimal("0")) { |row| row.interest_payment }
      end

      # The raw simulation, independent of #applicable? (which itself needs
      # to inspect this to determine convergence -- see #converged?).
      # Memoized: safe to call repeatedly within one instance's lifetime.
      def raw_schedule
        @raw_schedule ||= generate_schedule
      end

      def generate_schedule
        payment_dates = projected_payment_dates
        rate_resolver = Loan::RateResolver.for(loan)

        Loan::Simulator.new(
          starting_balance: current_balance.amount,
          starting_balance_as_of: Date.current,
          accrual_start_date: Date.current,
          payment_schedule: payment_dates,
          accrual_rate_for: rate_resolver.method(:accrual_rate_for),
          re_amortisation_events: rate_resolver.method(:re_amortisation_events),
          payment_strategy: :hold,
          payment_amount_for: ->(**_kwargs) { monthly_payment.amount },
          currency_precision: currency_precision,
          max_iterations: payment_dates.length,
          settle_at_schedule_end: false
        ).run.payments
      end

      def projected_payment_dates
        first_date = first_projected_payment_date
        max_iterations = MAX_ITERATIONS_MULTIPLIER * loan.term_months
        Array.new(max_iterations) do |index|
          first_date >> index
        end
      end

      def currency_precision
        Money::Currency.new(currency).default_precision
      end
  end
end
