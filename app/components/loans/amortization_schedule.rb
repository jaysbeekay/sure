class Loans::AmortizationSchedule < ApplicationComponent
  attr_reader :loan, :expanded

  def initialize(loan:, expanded: false)
    @loan = loan
    @expanded = expanded
  end

  def has_schedule?
    loan.amortization_schedules.exists?
  end

  def schedule_entries
    loan.amortization_schedules.order(:payment_number).limit(12)
  end

  def total_entries
    loan.amortization_schedules.count
  end

  def showing_all?
    schedule_entries.count == total_entries
  end

  def can_generate?
    loan.term_months.present? && loan.interest_rate.present?
  end

  def schedule_summary
    return nil unless has_schedule?

    total_interest = loan.amortization_schedules.sum(:interest_payment)
    total_principal = loan.amortization_schedules.sum(:principal_payment)

    {
      total_interest: Money.new(total_interest.round, loan.account.currency),
      total_principal: Money.new(total_principal.round, loan.account.currency),
      total_payments: loan.amortization_schedules.count
    }
  end
end
