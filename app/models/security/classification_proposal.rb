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
  validate :answers_something

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

    # The veto is re-checked INSIDE the row lock, not before it. Checked outside,
    # a concurrent manual save can commit between the check and the write, and
    # `security.update!` then silently overwrites the answer a person had just
    # given -- the precise case the veto exists to prevent, surviving only
    # because the two requests did not overlap.
    approved = false

    security.with_lock do
      security.reload
      next if security.classification_locked? || security.classification_source == "manual"

      security.update!(
        proposed_attributes.merge(classification_source: "ai", classification_locked: false)
      )
      update!(status: "approved")
      approved = true
    end

    approved
  end

  # Conditional for the same reason `approve!` is: a stale form from another tab
  # would otherwise move an already-approved proposal to `rejected` while the
  # security stays classified `"ai"`, leaving a row that denies a classification
  # still in force.
  def reject!
    return false unless pending?

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

    # A proposal with nothing in it was valid, storable AND approvable, and
    # approval stamped `classification_source: "ai"` on a security with no
    # classification at all. Since `"ai"` is not in the `[nil, "default"]` set
    # `classification_attributes_from` will overwrite, that security could then
    # never be classified by a provider again -- a permanent lock-out bought
    # with no information. The tool's `params_schema` requires only `ticker`,
    # so the model can send exactly this shape.
    def answers_something
      return if [ asset_class, asset_sub_class, sector, region ].any?(&:present?)

      errors.add(:base, "must propose at least one classification")
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
