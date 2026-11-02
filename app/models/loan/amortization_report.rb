# The figures the amortisation schedule API returns, read from the schedule
# upstream's engine computes on each call. Nothing is stored, so a response
# always matches the loan's current inputs and reading one never writes.
class Loan::AmortizationReport
  Row = Data.define(:payment_number, :payment_date, :payment_amount, :principal_payment,
                    :interest_payment, :beginning_balance, :ending_balance, :interest_rate)

  # A response is computed from the loan as it stands, so it is always current.
  STATUS = "current".freeze

  attr_reader :loan, :schedule

  def initialize(loan)
    @loan = loan
    @schedule = loan.amortization_schedule
  end

  def status
    STATUS
  end

  def total_count
    payments.size
  end

  def monthly_payment
    payments.first&.payment
  end

  def total_interest
    schedule.total_interest if payments.any?
  end

  def total_cost
    loan.original_balance + total_interest if payments.any?
  end

  def payoff_date
    schedule.payoff_date
  end

  def has_rate_changes?
    loan.variable_rate_type? && loan.variable_rate_schedule.present?
  end

  def next_rate_change_date(as_of: Date.current)
    return nil unless loan.variable_rate_type?

    loan.variable_rates.map { |date, _| Date.iso8601(date.to_s) }.find { |date| date > as_of }
  end

  # Past the last payment, an empty page rather than nil.
  def rows(offset:, limit:)
    Array(payments[offset, limit]).each_with_index.map do |payment, position|
      row_for(payment, offset + position)
    end
  end

  private
    def payments
      schedule.payments
    end

    def row_for(payment, index)
      previous = payments[index - 1] if index.positive?

      Row.new(
        payment_number: payment.number,
        payment_date: payment.date,
        payment_amount: payment.payment.amount,
        principal_payment: payment.principal.amount,
        interest_payment: payment.interest.amount,
        beginning_balance: previous ? previous.ending_balance.amount : schedule.principal,
        ending_balance: payment.ending_balance.amount,
        # The rate that accrued over the period, as the schedule charged it.
        interest_rate: rate_resolver.accrual_rate_for(previous ? previous.date : schedule.start_date)
      )
    end

    def rate_resolver
      @rate_resolver ||= Loan::RateResolver.for(loan)
    end
end
