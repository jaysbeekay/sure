class Loan < ApplicationRecord
  include Accountable

  SUBTYPES = {
    "mortgage" => { short: "Mortgage", long: "Mortgage" },
    "student" => { short: "Student Loan", long: "Student Loan" },
    "auto" => { short: "Auto Loan", long: "Auto Loan" },
    "home_equity" => { short: "Home Equity", long: "Home Equity Loan" },
    "line_of_credit" => { short: "Line of Credit", long: "Line of Credit" },
    "business" => { short: "Business Loan", long: "Business Loan" },
    "other" => { short: "Other Loan", long: "Other Loan" }
  }.freeze

  has_many :amortization_schedules, class_name: "LoanAmortizationSchedule", dependent: :delete_all

  validates :subtype, inclusion: { in: SUBTYPES.keys }, allow_blank: true

  def monthly_payment
    return nil if term_months.nil? || interest_rate.nil? || rate_type.nil?
    return Money.new(0, account.currency) if account.loan.original_balance.amount.zero? || term_months.zero?

    case rate_type
    when "fixed"
      calculate_fixed_rate_payment
    when "variable"
      current_payment_amount
    else
      nil
    end
  end

  # The payment effective right now -- the most recent payment on or before
  # today, so a variable-rate loan's displayed payment reflects the current
  # rate period rather than (as `.last` would) whatever the final period's
  # payment happens to be. Falls back to the first scheduled payment for a
  # schedule that hasn't started yet (start_date in the future).
  def current_payment_amount
    current_schedule = amortization_schedules.where("payment_date <= ?", Date.today).order(:payment_number).last ||
      amortization_schedules.order(:payment_number).first
    return nil if current_schedule.blank?

    Money.new(current_schedule.payment_amount.round, account.currency)
  end

  # Replaces the persisted schedule atomically: if any row fails to
  # generate, the transaction rolls back and the prior schedule (if any)
  # is left intact, rather than deleting it up front and risking a
  # partial replacement on failure.
  def generate_amortization_schedule(start_date: Date.today)
    return if term_months.nil? || interest_rate.nil?

    transaction do
      amortization_schedules.delete_all
      remaining_balance = original_balance.amount
      payment_number = 1
      current_date = start_date
      current_rate = interest_rate

      term_months.times do |i|
        current_rate = rate_for_date(current_date)

        monthly_rate = (current_rate / 100.0) / 12.0
        remaining_months = term_months - i

        # For variable rate loans, recalculate payment based on remaining balance and months
        if rate_type == "variable" && i > 0
          monthly_payment_amount = calculate_payment_amount(remaining_balance, monthly_rate, remaining_months)
        elsif monthly_rate.zero?
          monthly_payment_amount = remaining_balance / remaining_months
        else
          monthly_payment_amount = (remaining_balance * monthly_rate * (1 + monthly_rate)**remaining_months) / ((1 + monthly_rate)**remaining_months - 1)
        end

        interest_payment = remaining_balance * monthly_rate
        principal_payment = monthly_payment_amount - interest_payment
        ending_balance = remaining_balance - principal_payment

        LoanAmortizationSchedule.create!(
          loan_id: id,
          payment_number: payment_number,
          payment_date: current_date,
          beginning_balance: remaining_balance,
          payment_amount: monthly_payment_amount,
          principal_payment: principal_payment,
          interest_payment: interest_payment,
          ending_balance: [ ending_balance, 0 ].max,
          interest_rate: current_rate
        )

        remaining_balance = [ ending_balance, 0 ].max
        payment_number += 1
        current_date = current_date.next_month
      end
    end
  end

  def add_rate_change(effective_date, new_rate)
    schedule = (rate_change_schedule || {}).dup
    schedule[effective_date.to_s] = new_rate
    update(
      rate_change_schedule: schedule,
      next_rate_change_date: schedule.keys.map { |d| Date.parse(d) }.min
    )

    regenerate_amortization_schedule if amortization_schedules.exists?
  end

  # The rate in effect on `date` -- the loan's original `interest_rate`
  # before any configured change has taken effect yet (or none exist),
  # otherwise the most recent rate change at or before `date`.
  def rate_for_date(date)
    return interest_rate if rate_change_schedule.blank?

    applicable_rates = rate_change_schedule.select do |effective_date, _rate|
      Date.parse(effective_date) <= date
    end

    return interest_rate if applicable_rates.empty?

    latest_date = applicable_rates.keys.map { |d| Date.parse(d) }.max
    rate_change_schedule[latest_date.to_s]
  end

  def regenerate_amortization_schedule
    generate_amortization_schedule(start_date: (amortization_schedules.order(:payment_date).first&.payment_date || Date.today))
  end

  private

    def calculate_fixed_rate_payment
      annual_rate = interest_rate / 100.0
      monthly_rate = annual_rate / 12.0

      if monthly_rate.zero?
        payment = account.loan.original_balance.amount / term_months
      else
        payment = (account.loan.original_balance.amount * monthly_rate * (1 + monthly_rate)**term_months) / ((1 + monthly_rate)**term_months - 1)
      end

      Money.new(payment.round, account.currency)
    end

    def calculate_payment_amount(principal, monthly_rate, months_remaining)
      if monthly_rate.zero?
        principal / months_remaining
      else
        (principal * monthly_rate * (1 + monthly_rate)**months_remaining) / ((1 + monthly_rate)**months_remaining - 1)
      end
    end

    def original_balance
      Money.new(account.first_valuation_amount, account.currency)
    end

  class << self
    def color
      "#D444F1"
    end

    def icon
      "hand-coins"
    end

    def classification
      "liability"
    end
  end
end
