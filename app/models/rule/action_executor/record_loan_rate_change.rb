# Reads a new interest rate out of a loan transaction's description and records
# it as a dated change on the loan (#142, phase 2).
#
# Built without the real bank wordings the issue asked for, so the decisions
# below are deliberate and narrow rather than surveyed:
#
# - WHICH TRANSACTIONS. Only those on an account whose accountable is a Loan.
#   A rule's conditions can legitimately match other accounts as well, and
#   those are skipped without a word. A loan whose rate type is not variable --
#   fixed, or blank -- records nothing; a reading that disagrees with such a
#   loan's rate is logged, as the Redbark path logs it. A blank rate type is
#   NOT read as variable: Redbark adopts `variable` only on the bank's own
#   structured word for it, and a free-text description is not that.
# - WHAT IT READS. The transaction's name, then its notes, through
#   Loan::RateChangeText; the first that yields a rate wins. A percentage that
#   is there but cannot be used -- ambiguous, a change amount, out of range --
#   records nothing and is logged. Text with no percentage is silent.
# - WHEN. The change is dated at the transaction's own date (`entry.date`), and
#   nothing here reads the clock.
# - HOW IT WRITES. Through the provider path: Loan#variable_rate_update_for
#   decides the row, Loan#enrich_reporting_refusal writes it. So the same
#   guards apply as for Redbark and Plaid: a locked schedule is the user's and
#   is left alone, a rate equal to the one in force on that date is not a
#   change, a first reading on a loan with no base rate becomes the base rate,
#   and provenance is a DataEnrichment with source "rule". Never
#   Loan#add_variable_rate_change, which writes past the lock.
# - IT NEVER OVERWRITES A ROW. A row already on the transaction's date with a
#   different rate is left as it is and the clash is logged. This is stricter
#   than Loan#variable_rate_update_for on its own, which replaces a same-day
#   row; that suits a provider's latest reading of the day, but two notices on
#   one date disagreeing is a question for the user, not for whichever ran
#   last.
# - LOCKS ARE ALWAYS HONOURED. `ignore_attribute_locks` (set by "apply rule"
#   in the UI) is about the transaction attributes rules own. It does not give
#   a rule the user's hand-edited loan schedule.
# - IT DOES NOT EXCLUDE THE TRANSACTION. A rate notice is usually a $0 line;
#   add the existing "Exclude from budgeting and reports" action to the same
#   rule to hide it. Folding that in would make one action do two things.
class Rule::ActionExecutor::RecordLoanRateChange < Rule::ActionExecutor
  SOURCE = "rule"
  DEBUG_CATEGORY = "loan_rate"

  def label
    I18n.t("rule.actions.record_loan_rate_change.label")
  end

  # Returns how many transactions led to a write on their loan.
  def execute(transaction_scope, value: nil, ignore_attribute_locks: false, rule_run: nil)
    # DATE ORDER, oldest first. Whether a rate is a change depends on the rate
    # in force on that date, which depends on every earlier row; read newest
    # first, the same notice repeated months apart records twice.
    scope = transaction_scope
      .with_entry
      .where(accounts: { accountable_type: "Loan" })
      .includes(entry: :account)
      .reorder(Arel.sql("entries.date ASC, entries.created_at ASC, entries.id ASC"))

    count_modified_resources(scope) do |transaction|
      entry = transaction.entry
      record(entry.account.accountable, entry)
    end
  end

  private
    # True when the loan was written.
    def record(loan, entry)
      reading = read(entry)

      if reading.rate.nil?
        if reading.problem
          report(entry, "A loan rate could not be read from the transaction; recording none",
                 problem: reading.problem.to_s, candidates: reading.candidates.map(&:to_s))
        end
        return false
      end

      rate = reading.rate

      unless loan.variable_rate_type?
        # A fixed loan's rate does not move, so a description disagreeing with
        # it is something to surface, not something to write.
        if loan.interest_rate.present? && BigDecimal(loan.interest_rate.to_s) != rate
          report(entry, "A loan rate was read for a loan that is not variable; recording none",
                 problem: "not_variable", rate_type: loan.rate_type, read: rate.to_s, recorded: loan.interest_rate.to_s)
        end
        return false
      end

      date = entry.date
      # Matched by parsed date, not by key: ISO-8601 spells a day more than one
      # way ("2026-09-14", "20260914"), and a row under either is on this date
      # (cubic, #400).
      existing = loan.variable_rates.find { |key, _| Date.iso8601(key.to_s) == date }&.last
      if existing.present? && BigDecimal(existing.to_s) != rate
        report(entry, "A loan rate clashes with a rate already recorded on that date; recording none",
               problem: "date_clash", read: rate.to_s, recorded: existing.to_s)
        return false
      end

      update = loan.variable_rate_update_for(rate, as_of: date)
      return false if update.nil?

      before = update.keys.index_with { |attr| loan.public_send(attr) }
      messages = loan.enrich_reporting_refusal(update, source: SOURCE, metadata: { rule_id: rule.id, entry_id: entry.id })

      if messages
        report(entry, "A loan rate was refused by the loan; recording none",
               problem: "refused", read: rate.to_s, errors: messages)
        return false
      end

      # A locked attribute is skipped by Enrichable without a word, so whether
      # anything was written is read off the loan rather than assumed.
      update.keys.any? { |attr| loan.public_send(attr) != before[attr] }
    end

    def read(entry)
      by_name = Loan::RateChangeText.read(entry.name)
      return by_name if by_name.rate

      by_notes = Loan::RateChangeText.read(entry.notes)
      return by_notes if by_notes.rate

      by_name.problem ? by_name : by_notes
    end

    def report(entry, message, **metadata)
      DebugLogEntry.capture(
        category: DEBUG_CATEGORY,
        level: "warn",
        message: message,
        source: self.class.name,
        family: family,
        account: entry.account,
        metadata: metadata.merge(rule_id: rule.id, entry_id: entry.id, loan_id: entry.account.accountable_id)
      )
    end
end
