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
end
