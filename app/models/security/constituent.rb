# One line of a fund's holdings, as the provider reports it.
#
# `weight` is the provider's own percentage of fund assets and is stored
# unnormalised on purpose -- see the migration. `Security#look_through_weights`
# is what normalises, and it does so against the actual sum rather than against
# 100, because a fund's reported holdings rarely sum to exactly 100.
class Security::Constituent < ApplicationRecord
  belongs_to :security

  validates :ticker, presence: true
  validates :ticker, uniqueness: { scope: :security_id }
  # Zero is ALLOWED, and this is not a cosmetic boundary: EODHD reports a
  # rounded `Assets_%` and returns 0 for a position too small to round up to
  # 0.01. Under `greater_than: 0` that row failed validation, `create!` raised,
  # and the transaction in `store_constituents` took the ENTIRE fund's holdings
  # down with it -- so one negligible position cost the whole look-through.
  validates :weight, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true

  # The unaccounted look-through weight: the gap between 100 and whatever the
  # reported constituent weights actually sum to. A fund's reported holdings
  # rarely sum to exactly 100 (providers round, drop sub-0.01 rows, and the
  # cash/other/feeder sleeve never appears in a holdings list at all), so the
  # normalisation against the real sum leaves that gap unaccounted. Filing it
  # as an "unclassified / other" bucket keeps both look-through views
  # (statement and sibling portfolio) allocating the full 100 of parent weight
  # and keeps the two implementations honest against each other -- it lives
  # here, on `Security::Constituent`, so both `InvestmentStatement#
  # constituent_weights_for` and `Security::Provided#look_through_weights`
  # read the same source of truth.
  #
  # The clamp to >= 0 mirrors the guard the two call sites already apply
  # (negative input would mean the reported weights OVER-sum, which is a data
  # problem worth logging, not silently filing as "unclassified" negative).
  def self.look_through_remainder(weights)
    sum = weights.sum do |weight|
      value = weight.to_f
      value.nan? ? 0.0 : value
    end
    [100.0 - sum, 0.0].max
  end
end
