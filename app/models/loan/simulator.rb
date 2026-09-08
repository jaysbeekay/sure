class Loan
  # The period engine. Walks a payment schedule, charging interest and applying
  # payments, and returns a SimulationResult.
  #
  # It takes values and callables rather than a Loan, so the contracted schedule
  # and (later) a projection from today's balance can share one loop instead of
  # growing two implementations that drift.
  #
  # ## Accrual is monthly
  #
  # One interest charge per period, on the balance outstanding when the period
  # opened. Daily accrual is a different engine and is deliberately not here.
  #
  # ## Two rates, not one
  #
  # A period is bounded by two dates, and on a variable loan they can sit either
  # side of a rate change. Which rate applies depends on what is being asked:
  #
  #   * **Interest** for the period [previous payment date, this payment date)
  #     accrues at the rate in force when the period **opened**. A rate that
  #     becomes effective on this period's closing date belongs to the NEXT
  #     window, not to the month that has already run at the old rate.
  #   * **Payment sizing** uses the rate in force **on** the payment date, so a
  #     change effective on a payment date resizes that payment.
  #
  # Reading a single rate for both re-rates the period ending on the boundary --
  # the borrower is charged a rate that did not apply for any day of the month
  # being billed. Keeping them apart is the whole reason `accrual_rate_for` is
  # called twice with different dates below.
  #
  # Under monthly accrual a rate change *mid*-period cannot move that period's
  # interest: there is one charge, computed at the period's opening rate. It
  # takes effect from the following period. That is a property of monthly
  # accrual, not an approximation to be corrected here.
  class Simulator
    # Guards a runaway schedule: a hundred years of monthly payments.
    MAX_PERIODS = 1200

    PAYMENT_STRATEGIES = %i[reamortize hold].freeze

    def initialize(
      starting_balance:,
      accrual_start_date:,
      payment_schedule:,
      accrual_rate_for:,
      currency_precision:,
      re_amortisation_events: nil,
      payment_strategy: :reamortize,
      payment_amount: nil,
      extra_for: nil,
      settle_at_schedule_end: true
    )
      @starting_balance = BigDecimal(starting_balance.to_s)
      @accrual_start_date = accrual_start_date
      @payment_schedule = payment_schedule.to_a.freeze
      @accrual_rate_for = callable!(accrual_rate_for, :accrual_rate_for)
      @re_amortisation_events = callable!(
        re_amortisation_events || ->(_from, _to) { [] }, :re_amortisation_events
      )
      @currency_precision = currency_precision
      @payment_strategy = payment_strategy.to_sym
      # A caller-supplied repayment. A projection holds the CONTRACTED payment
      # against a balance that is no longer the contracted one -- which is the
      # whole question it exists to answer -- so it cannot let the simulator
      # size a payment from the balance in front of it.
      @payment_amount = payment_amount.nil? ? nil : BigDecimal(payment_amount.to_s)
      @extra_for = callable!(extra_for || ->(_from, _to) { [] }, :extra_for)
      @settle_at_schedule_end = settle_at_schedule_end

      raise ArgumentError, "payment schedule must not be empty" if @payment_schedule.empty?
      unless PAYMENT_STRATEGIES.include?(@payment_strategy)
        raise ArgumentError, "unsupported payment strategy: #{@payment_strategy.inspect}"
      end
    end

    def run
      balance = @starting_balance
      payments = []
      payment = nil
      previous_sizing_rate = nil
      periods = [ @payment_schedule.length, MAX_PERIODS ].min

      (0...periods).each do |index|
        break if balance <= 0

        payment_date = @payment_schedule[index]
        period_start = index.zero? ? @accrual_start_date : @payment_schedule[index - 1]

        # Extra repayments land on their own dates and reduce the balance from
        # there, so the interest charged for the period is charged on what was
        # actually outstanding. Applied before accrual for exactly that reason:
        # crediting them at the period boundary instead would quietly hand back
        # the interest saving the borrower paid for.
        balance = apply_extra_repayments(balance, period_start, payment_date)
        break if balance <= 0

        # See the class comment: opening rate charges the period, closing rate
        # sizes the payment.
        accrual_rate = monthly_rate(@accrual_rate_for.call(period_start))
        sizing_rate = monthly_rate(rate_on(payment_date))

        # Resize only when the sizing rate actually moves. Recomputing every
        # period would be arithmetically identical while the rate holds, but it
        # would also silently absorb a payment the borrower is contracted to,
        # which is what `:hold` exists to refuse.
        if @payment_amount
          payment = @payment_amount
        elsif payment.nil? || (@payment_strategy == :reamortize && sizing_rate != previous_sizing_rate)
          payment = AmortizationMath.level_payment(
            balance: balance,
            monthly_rate: sizing_rate,
            remaining_payments: @payment_schedule.length - index,
            currency_precision: @currency_precision
          )
        end
        previous_sizing_rate = sizing_rate

        interest = (balance * accrual_rate).round(@currency_precision)
        final = (@settle_at_schedule_end && index == @payment_schedule.length - 1) ||
          payment >= balance + interest

        step = AmortizationMath.step(
          balance: balance,
          payment: payment,
          monthly_rate: accrual_rate,
          currency_precision: @currency_precision,
          final: final,
          interest: interest
        )

        payments << {
          payment_number: index + 1,
          payment_date: payment_date,
          interest_rate: BigDecimal(rate_on(payment_date).to_s),
          **step
        }

        balance = step[:ending_balance]
      end

      SimulationResult.new(
        payments: payments,
        converged: balance.zero?,
        balloon_amount: balance,
        currency_precision: @currency_precision
      )
    end

    private
      # Extra repayments falling in [from_date, to_date), summed. The window is
      # half-open at the top: a repayment dated on a payment date belongs to
      # that payment's own period, not to the one after it.
      def apply_extra_repayments(balance, from_date, to_date)
        extras = Array(@extra_for.call(from_date, to_date)).sum(BigDecimal("0")) do |change|
          date = change.fetch(:date)
          next BigDecimal("0") unless date >= from_date && date <= to_date

          BigDecimal(change.fetch(:amount).to_s)
        end
        return balance if extras.zero?

        [ balance - extras, BigDecimal("0") ].max
      end

      # The contracted rate on a given payment date: a re-amortisation event
      # effective that day, otherwise whatever the rate curve says.
      def rate_on(date)
        event = re_amortisation_rates.reverse.find { |effective, _| effective <= date }
        event ? event.last : @accrual_rate_for.call(date)
      end

      def re_amortisation_rates
        @re_amortisation_rates ||= @re_amortisation_events
          .call(@payment_schedule.first, @payment_schedule.last)
          .map { |event| [ event.fetch(:date), event.fetch(:rate) ] }
          .sort_by(&:first)
      end

      def monthly_rate(annual_percentage)
        (BigDecimal(annual_percentage.to_s) / BigDecimal("100")) / BigDecimal("12")
      end

      def callable!(value, name)
        raise ArgumentError, "#{name} must respond to #call" unless value.respond_to?(:call)

        value
      end
  end
end
