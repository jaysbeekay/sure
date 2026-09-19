# What the assistant thinks a security is, held separately from what it IS.
#
# The separation is the point. `classification_source` exists so a figure in an
# allocation chart can be traced to whoever asserted it, and a model that wrote
# straight to `securities` would be indistinguishable from a provider. So the
# assistant writes here, a person approves, and only approval touches the
# security.
#
# Family-scoped, because the proposal belongs to the household whose assistant
# made it. Its EFFECT is not: approving writes the globally shared `securities`
# row, exactly as 3.3's manual override does.
class Security::ClassificationProposal < ApplicationRecord
  STATUSES = %w[pending approved rejected].freeze

  belongs_to :security
  belongs_to :family

  validates :status, inclusion: { in: STATUSES }
  # The same vocabularies `Security` validates, and for a concrete reason: they
  # are database check constraints on `securities`, so storing a proposal that
  # could not be approved would only defer the failure to approval time.
  validates :asset_class, inclusion: { in: Security::ASSET_CLASSES }, allow_nil: true
  validates :asset_sub_class, inclusion: { in: Security::ASSET_SUB_CLASSES }, allow_nil: true
  validates :region, inclusion: { in: Security::REGION_KEYS }, allow_nil: true
  validate :security_is_open_to_a_proposal, on: :create

  scope :pending, -> { where(status: "pending") }

  STATUSES.each do |state|
    define_method("#{state}?") { status == state }
  end

  # Replaces any existing proposal for this pair rather than accumulating, so a
  # review screen can never show one security twice with two different answers.
  # The unique index on (family_id, security_id) is what makes that a guarantee
  # rather than a convention.
  def self.propose!(security:, family:, **attrs)
    existing = find_by(security: security, family: family)
    return existing.tap { |p| p.update!(status: "pending", **attrs) } if existing

    create!(security: security, family: family, **attrs)
  end

  # Returns false rather than raising when the security has been answered since
  # the proposal was made -- that window is exactly where a user can pick up the
  # drawer and classify it by hand, and their answer wins.
  def approve!
    return false unless pending?
    return false if security.classification_locked? || security.classification_source == "manual"

    transaction do
      security.update!(
        proposed_attributes.merge(classification_source: "ai", classification_locked: false)
      )
      update!(status: "approved")
    end

    true
  end

  def reject!
    update!(status: "rejected")
  end

  private
    # Only the columns this proposal actually answered. A proposal that could
    # only name the region must not blank out an asset class the security
    # already holds.
    def proposed_attributes
      { asset_class: asset_class, asset_sub_class: asset_sub_class,
        sector: sector, region: region }.compact_blank
    end

    def security_is_open_to_a_proposal
      return if security.blank?

      if security.classification_locked?
        errors.add(:security, "has a locked classification")
      elsif security.classification_source == "manual"
        errors.add(:security, "has already been classified by hand")
      end
    end
end
