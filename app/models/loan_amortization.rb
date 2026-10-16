# Stores individual payment records for an amortization schedule.
#
# A cache (#184, 2026-09-30): the rows are written from the contracted
# schedule (Loan#amortization_rows, upstream's Loan::AmortizationSchedule) by
# LoanAmortizationRebuildJob and the loans:rebuild_schedules task, and read by
# GET /api/v1/loans/:id/amortization_schedule. Nothing on the account page
# reads them: every figure there comes from the in-memory schedule.
class LoanAmortization < ApplicationRecord
  # The version of the calculation the cached rows were produced by. It is
  # baked into Loan#amortization_schedule_signature, so bumping it restages
  # every persisted schedule; it has to move whenever the figures do. Deploying
  # a bump needs the prebuild in docs/loans/release-evidence.md, since read
  # paths enqueue rebuilds rather than performing them (#39).
  #
  # 4 (#184): a re-amortisation sized from the interest its opening period
  # charged.
  # 5 (#184, direction C): the rows come from upstream's engine. A loan drawn
  # down on the 29th-31st pays on that day again after a short month
  # (`origination >> n`, not chained `next_month`), and a row's interest_rate
  # is the rate the period opened on, not the rate its payment was sized at.
  ALGORITHM_VERSION = 5

  belongs_to :loan

  validates :payment_number, presence: true, numericality: { only_integer: true, greater_than: 0 }
  validates :payment_date, presence: true
  validates :payment_amount, :principal_payment, :interest_payment, :beginning_balance, :ending_balance, :interest_rate, :schedule_signature, :algorithm_version, :generated_at, presence: true

  # Order payments by payment number
  scope :ordered, -> { order(payment_number: :asc) }
end
