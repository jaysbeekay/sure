# The one write path for a loan's terms from a Plaid payload, shared by the
# mortgage and student-loan processors (#158).
#
# Both used to call `loan.update!` straight from the payload, which had three
# consequences and no way to tell them apart:
#
# - A value the user corrected on the loan form is LOCKED by
#   `Account#lock_saved_attributes!`, and `update!` overwrote it on the very
#   next sync. The student-loan processor sent `rate_type: "fixed"` every time,
#   so a loan the user marked variable reverted on each sync.
# - Nothing recorded that the provider was the author, so a later writer had no
#   way to know whose value it was looking at.
# - A payload that OMITS a field sent `nil`, which blanked the stored value. A
#   mortgage without a `percentage` erased the rate the user had typed in.
#
# `Enrichable#enrich_attributes` answers the first two: it skips locked
# attributes and records a `DataEnrichment` per attribute it writes. The third
# is `compact` below -- an omitted value is not a value.
module PlaidAccount::Liabilities::LoanTermWriter
  extend ActiveSupport::Concern

  private
    # `compact`, NOT `compact_blank`. A rate of exactly `0` is a real figure --
    # an interest-free loan is a thing a provider reports -- and `compact_blank`
    # would drop it along with the nils. The distinction being drawn is
    # "the payload did not say" versus "the payload said zero".
    def write_loan_terms(**attrs)
      loan = account.loan
      return if loan.blank?

      present = attrs.compact
      return if present.empty?

      loan.enrich_attributes(present, source: "plaid")
      return if loan.errors.empty?

      # `enrich_attributes` calls `save`, not `save!`, so an invalid value
      # returns false rather than raising. On `main` the `update!` raised into
      # `PlaidAccount::Processor#process_liabilities`'s `rescue`, which reported
      # it; without this the failure would become silent, which is a worse
      # outcome than the one being fixed.
      #
      # `false` alone is not a failure -- Enrichable also returns it when every
      # attribute was locked or unchanged, which are the ordinary quiet paths.
      # Only a populated `errors` distinguishes a refusal.
      DebugLogEntry.capture(
        category: "provider_sync",
        level: "warn",
        message: "Plaid loan terms refused by the model",
        source: self.class.name,
        provider_key: "plaid",
        account: account,
        metadata: {
          plaid_account_id: plaid_account.id,
          attributes: present.keys.map(&:to_s),
          errors: loan.errors.full_messages
        }
      )

      # Put the loan back the way it was found. `enrich_attributes` assigns and
      # then calls `save`; a refusal leaves the REJECTED VALUES on the in-memory
      # loan with its errors populated, so anything reading it later in the same
      # sync sees a figure the model would not store. Clearing the errors
      # matters separately: `enrich_attributes` returns early without saving
      # when every attribute is locked or unchanged, so a later write in the
      # same pass would find these errors sitting there and report a refusal
      # that never happened.
      #
      # The same fix `RedbarkAccount::LoanDetailsProcessor#write` carries -- it
      # was raised there first and should have been carried across with the
      # pattern rather than waiting to be raised again here (cubic, #222).
      loan.restore_attributes(present.keys.map(&:to_s))
      loan.errors.clear
    end
end
