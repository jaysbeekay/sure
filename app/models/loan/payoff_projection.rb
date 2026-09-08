class Loan
  # Where the loan is actually heading, starting from today's real balance
  # rather than from the contract.
  #
  # The contracted schedule answers "what did you agree to?". This answers "what
  # is going to happen?", and the gap between them is the whole point: a
  # borrower who has overpaid is ahead of the schedule, one whose balance has
  # grown is behind, and neither is visible from the contract alone.
  #
  # It holds the CONTRACTED repayment against a balance that is no longer the
  # contracted one. That is deliberate -- re-sizing the repayment to today's
  # balance would answer a different and much less useful question, and would
  # make every loan look exactly on track by construction.
  class PayoffProjection
    attr_reader :loan, :as_of

    def initialize(loan, as_of: Date.current)
      @loan = loan
      @as_of = as_of
    end

    # False when there is nothing to project: no schedule, nothing left to owe,
    # no payments remaining, or no repayment to hold.
    def applicable?
      schedule.present? &&
        current_balance.amount.positive? &&
        remaining_payment_dates.any? &&
        contracted_payment&.positive? || false
    end

    def currency
      loan.account.currency
    end

    def current_balance
      @current_balance ||= Money.new(loan.account.balance, currency)
    end

    def payments
      simulation&.payments || []
    end

    def payoff_date
      simulation&.payoff_date
    end

    def total_interest
      Money.new(simulation&.total_interest || 0, currency)
    end

    # False when the contracted repayment does not clear the balance by the
    # original maturity -- the borrower is far enough behind that the contract
    # no longer pays the loan off. There is no payoff date in that case.
    def converged?
      simulation ? simulation.converged? : false
    end

    def balloon_amount
      Money.new(simulation&.balloon_amount || 0, currency)
    end

    # Positive means the loan finishes earlier than the contract said.
    def months_saved
      return 0 unless applicable? && converged?

      remaining_payment_dates.length - payments.length
    end

    # Positive means less interest than the contract's remaining interest.
    def interest_saved
      return Money.new(0, currency) unless applicable?

      Money.new(remaining_contracted_interest - (simulation&.total_interest || 0), currency)
    end

    private
      def schedule
        @schedule ||= loan.amortization_schedule
      end

      # The payment dates still ahead. A projection runs to the ORIGINAL
      # maturity and no further: extending it would invent a term the borrower
      # never agreed to.
      def remaining_payment_dates
        @remaining_payment_dates ||= (schedule&.payments || [])
          .select { |payment| payment.date > as_of }
          .map(&:date)
      end

      # The repayment in force: the next scheduled payment's amount. For a
      # re-amortising loan that is the figure the current rate produced, which
      # is what the borrower is actually paying.
      def contracted_payment
        @contracted_payment ||= (schedule&.payments || [])
          .find { |payment| payment.date > as_of }&.payment&.amount
      end

      def remaining_contracted_interest
        (schedule&.payments || [])
          .select { |payment| payment.date > as_of }
          .sum(BigDecimal("0")) { |payment| payment.interest.amount }
      end

      def simulation
        return nil unless applicable?

        @simulation ||= Simulator.new(
          starting_balance: current_balance.amount,
          accrual_start_date: as_of,
          payment_schedule: remaining_payment_dates,
          accrual_rate_for: rate_resolver.method(:accrual_rate_for),
          re_amortisation_events: rate_resolver.method(:re_amortisation_events),
          payment_amount: contracted_payment,
          # Seeded with the contracted repayment, but still re-amortising at
          # each recorded rate change -- because that is what the contract
          # itself does on a variable loan. Holding one figure to maturity
          # would project a repayment the lender will never ask for. On a fixed
          # loan there are no changes, so it holds, which is the whole basis of
          # the ahead/behind comparison.
          payment_strategy: :reamortize,
          currency_precision: currency_precision,
          # A projection that cannot clear the balance must SAY so. Settling the
          # final payment regardless would manufacture a payoff date for a loan
          # the contract no longer pays off.
          settle_at_schedule_end: false
        ).run
      end

      def rate_resolver
        @rate_resolver ||= RateResolver.for(loan)
      end

      def currency_precision
        @currency_precision ||= Money::Currency.new(currency).default_precision || 2
      end
  end
end
