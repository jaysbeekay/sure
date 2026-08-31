class LoanAmortizationSchedule < ApplicationRecord
  belongs_to :loan

  validates :loan_id, :payment_number, :payment_date, presence: true
  validates :beginning_balance, :payment_amount, :principal_payment, :interest_payment, :ending_balance, :interest_rate, presence: true, numericality: true
  validates :payment_number, uniqueness: { scope: :loan_id }

  scope :by_payment_number, ->(num) { where(payment_number: num) }
  scope :after_date, ->(date) { where("payment_date >= ?", date) }
end
