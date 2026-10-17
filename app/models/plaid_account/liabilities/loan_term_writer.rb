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
# is `compact` below -- an omitted value is not a value. A variable loan's rate
# change is dated rather than overwritten (#223), using the sync's `as_of`,
# which each including processor supplies.
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

      # A variable loan's new rate is a dated schedule row, not a new base rate
      # (#223): overwriting the base rate re-prices every period before the
      # change. The other terms go first, so a payload that reclassifies the
      # loan is applied before its rate is judged.
      rate = present[:interest_rate]
      if rate && variable_after_write?(loan, present)
        write_terms_then_rate(loan, present.except(:interest_rate), rate)
      else
        write_enriched(loan, present)
      end
    end

    # Two saves, because the rate is judged against the loan the terms
    # produce. They still land together or not at all, as the single save
    # before #223 did: split, a reclassification to variable could commit while
    # the rate that came with it was refused (CodeRabbit, #247).
    #
    # The refusal is reported after the rollback, not inside it, or the log
    # entry would be rolled back with the terms.
    def write_terms_then_rate(loan, terms, rate)
      refusal = nil
      loan.transaction(requires_new: true) do
        refusal = enrich(loan, terms) || enrich(loan, variable_rate_update(loan, rate))
        raise ActiveRecord::Rollback if refusal
      end
      return if refusal.nil?

      # The rolled-back first save left its values on the in-memory loan.
      loan.reload
      report_refusal(*refusal)
    end

    # What a reported rate changes on a variable loan, or nil when it changes
    # nothing. A loan with no rate yet takes it as its base rate: a schedule row
    # would claim a change on a day nothing is known to have moved. A rate equal
    # to the one in force on `as_of` (a same-day repeat included) is no change.
    # Anything else is dated `as_of`. Rounded to three places so a reading that
    # wobbles in the fourth does not record a row on every sync. Stored as the
    # loan form stores a rate (Loan#rate_changes=), a plain decimal string.
    #
    # The same rules RedbarkAccount::LoanDetailsProcessor applies, on upstream's
    # Loan API: `current_variable_rate` and `variable_rate_schedule`. Called
    # only once `variable_after_write?` holds, so the loan is variable here.
    def variable_rate_update(loan, reported_rate)
      rate = BigDecimal(reported_rate.to_s).round(3)
      return { interest_rate: rate } if loan.interest_rate.blank?

      in_force = loan.current_variable_rate(as_of)
      return nil if in_force.present? && BigDecimal(in_force.to_s) == rate

      schedule = (loan.variable_rate_schedule || {}).stringify_keys
      { variable_rate_schedule: schedule.merge(as_of.to_date.iso8601 => rate.to_s("F")) }
    end

    # Whether the loan will be variable once this payload's `rate_type` is
    # applied. A locked `rate_type` is the user's and is not replaced.
    def variable_after_write?(loan, present)
      applied = present.key?(:rate_type) && !loan.locked?(:rate_type)
      rate_type = applied ? present[:rate_type] : loan.rate_type
      Loan::VARIABLE_RATE_TYPES.include?(rate_type.to_s)
    end

    def write_enriched(loan, present)
      refusal = enrich(loan, present)
      report_refusal(*refusal) if refusal
    end

    # Writes through Enrichable and returns nil, or `[attributes, messages]`
    # when the model refused them.
    def enrich(loan, present)
      return nil if present.blank?

      loan.enrich_attributes(present, source: "plaid")
      return nil if loan.errors.empty?

      messages = loan.errors.full_messages

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
      [ present, messages ]
    end

    # `enrich_attributes` calls `save`, not `save!`, so an invalid value
    # returns false rather than raising. On `main` the `update!` raised into
    # `PlaidAccount::Processor#process_liabilities`'s `rescue`, which reported
    # it; without this the failure would become silent, which is a worse
    # outcome than the one being fixed.
    #
    # `false` alone is not a failure -- Enrichable also returns it when every
    # attribute was locked or unchanged, which are the ordinary quiet paths.
    # Only a populated `errors` distinguishes a refusal (see #enrich).
    def report_refusal(present, messages)
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
          errors: messages
        }
      )
    end
end
