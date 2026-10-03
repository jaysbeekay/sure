# A manual override on one event: `included` pulls in a transaction dated
# outside the event's range, `excluded` removes one dated inside it. The
# transaction's date decides everything else, so there is no row for the
# ordinary case.
class EventTransaction < ApplicationRecord
  INCLUSIONS = %w[included excluded].freeze

  belongs_to :event
  belongs_to :transaction_record, class_name: "Transaction", foreign_key: :transaction_id

  validates :inclusion, inclusion: { in: INCLUSIONS }
  validates :transaction_id, uniqueness: { scope: :event_id }
  validate :transaction_belongs_to_events_family

  scope :included, -> { where(inclusion: "included") }
  scope :excluded, -> { where(inclusion: "excluded") }

  private
    def transaction_belongs_to_events_family
      return if event&.family.nil? || transaction_record.nil?

      errors.add(:transaction_record, :wrong_family) unless event.family.transactions.exists?(id: transaction_id)
    end
end
