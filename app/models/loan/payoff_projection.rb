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
  # Scoped to fixed-rate loans only for now -- see #3332.
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
      @loan.ensure_amortization_schedule_current!
      @schedule_cache = nil
    end

    def currency
      @currency ||= loan.account.currency
    end

    # Only fixed-rate loans with a real payment amount and a positive
    # current balance are eligible -- and only when there's actually
    # something to project (the original schedule must be amortizable).
    def applicable?
      loan.amortization_schedule.amortizable? &&
        loan.amortization_schedule.fixed_rate? &&
        monthly_payment.present? && monthly_payment.amount.positive? &&
        current_balance.amount.positive? &&
        !unamortizable_payment?
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
      @schedule_cache ||= generate_schedule
    end

    def payment_count
      payments.length
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
        monthly_rate = (loan.interest_rate / 100.0) / 12.0
        return false if monthly_rate.zero?

        first_interest = current_balance.amount * monthly_rate
        monthly_payment.amount <= first_interest
      end

      def original_remaining_payments
        @original_remaining_payments ||= loan.amortizations.where("payment_date > ?", Date.current).ordered
      end

      def original_remaining_payment_count
        original_remaining_payments.count
      end

      def original_remaining_interest
        original_remaining_payments.sum(:interest_payment)
      end

      def generate_schedule
        schedule = []
        balance = current_balance.amount
        payment = monthly_payment.amount
        annual_rate = loan.interest_rate / 100.0
        monthly_rate = annual_rate / 12.0
        current_date = Date.current.next_month
        payment_num = 1
        max_iterations = MAX_ITERATIONS_MULTIPLIER * loan.term_months

        # Unlike AmortizationSchedule (which knows its final period in
        # advance via term_months and force-clears the balance there), this
        # simulation only knows a period is final once the level payment
        # would fully cover the remaining balance. On an unchanged balance,
        # that can trail the original schedule by one small "cleanup"
        # payment after many periods of accumulated monthly rounding -- an
        # expected artifact of two independently-terminated simulations,
        # not a bug.
        while balance > 0 && payment_num <= max_iterations
          tentative_interest = (balance * monthly_rate).round(currency_precision)
          final = (payment - tentative_interest) >= balance

          step = AmortizationMath.step(
            balance: balance,
            payment: payment,
            monthly_rate: monthly_rate,
            currency_precision: currency_precision,
            final: final
          )

          schedule << {
            payment_number: payment_num,
            payment_date: current_date,
            interest_rate: loan.interest_rate,
            **step
          }

          balance = step[:ending_balance]
          current_date = current_date.next_month
          payment_num += 1
        end

        schedule
      end

      def currency_precision
        Money::Currency.new(currency).default_precision
      end
  end
end
