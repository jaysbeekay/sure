# frozen_string_literal: true

# Reads a loan's rate from what the bank reported, and records a change in the
# one place a loan's rates live: `loans.variable_rate_schedule` (#142, phase 1).
#
# THE DATE IS THE DAY IT WAS SEEN, and that is a limitation rather than a
# choice. `GET /v1/account-details` reports the rate in force right now and
# carries no effective date and no history -- neither `lendingRate` nor any
# entry in `lendingRates[]` has one, and the CDR standard behind it does not
# either. So a change detected on the 21st is recorded as the 21st even if the
# bank moved it on the 14th. Dating it earlier would be inventing a fact.
#
# `as_of` is INJECTED and never read from the clock in here. A sync that spans
# midnight, a replay, and a test all need the schedule keyed to the date the
# caller means, and a loan's figures are derived from those keys.
class RedbarkAccount::LoanDetailsProcessor
  SOURCE = "redbark"

  attr_reader :redbark_account, :as_of

  def initialize(redbark_account, as_of:)
    @redbark_account = redbark_account
    @as_of = as_of
  end

  def process
    return unless loan
    return if details.blank?
    return unless details_fetched_this_sync?

    apply_loan_terms
    apply_rate
  end

  private
    # A payload the sync did not refresh is a previous answer, not a current
    # one. Acting on it can record a change that never happened: the fetch
    # fails, the stored snapshot still holds last week's rate, the user has
    # since corrected the loan by hand, and the stale figure is written back
    # over their correction as though the bank had just reported it (raised by
    # cubic on #213).
    #
    # Keyed to the sync's own date rather than to a duration, because `as_of`
    # is the only notion of "now" this class is allowed. RedbarkItem::Syncer
    # reads the clock ONCE and hands the same instant to the import that writes
    # this stamp and to the processing that supplies `as_of`, so the comparison
    # below is a clock against itself; two readings would make a sync that
    # crosses midnight reject the snapshot it had just stored. A second sync on
    # the same day after a failed fetch re-reads a snapshot that was fresh this
    # morning, which is harmless: the rate has not moved, so nothing is
    # recorded.
    def details_fetched_this_sync?
      fetched_at = redbark_account.account_details_fetched_at
      return false if fetched_at.blank?

      fetched_at.to_date == as_of.to_date
    end

    def account
      @account ||= redbark_account.current_account
    end

    def loan
      return @loan if defined?(@loan)

      @loan = account&.accountable_type == "Loan" ? account.accountable : nil
    end

    def details
      @details ||= redbark_account.raw_account_details_payload&.deep_symbolize_keys || {}
    end

    # The headline rate first, because it is the bank's own answer to "what is
    # this loan's rate". `lendingRates[]` is a product description: it can carry
    # several rate types, and `tiers` can split one of those into bands, so a
    # single figure cannot be pulled from it unless exactly one candidate
    # survives.
    def reported_rate
      return @reported_rate if defined?(@reported_rate)

      @reported_rate = to_percentage(details[:lendingRate]) || single_variable_rate
    end

    def single_variable_rate
      rates = details[:lendingRates]

      unless rates.is_a?(Array)
        # Not an error: a deposit account has no lending rates, and a bank that
        # reports none for a loan is "nothing to say", not "malformed". Only a
        # shape that is neither absent nor an array is worth a line.
        capture("Redbark account details carried no usable lendingRates", shape: rates.class.name) unless rates.nil?
        return nil
      end

      candidates = rates.select { |entry| entry.is_a?(Hash) && entry[:rateType].to_s.casecmp("VARIABLE").zero? }
      # A tiered rate is several rates wearing one entry: which band applies
      # depends on the balance, and the payload does not say which one the
      # account sits in.
      candidates = candidates.reject { |entry| Array(entry[:tiers]).any? }

      if candidates.size > 1
        capture("Redbark reported several variable rates; recording none", candidate_count: candidates.size)
        return nil
      end

      to_percentage(candidates.first&.dig(:rate))
    end

    # The API reports fractions: "0.0675" is 6.75%. The schedule and
    # `interest_rate` are both percentages.
    def to_percentage(value)
      return nil if value.blank?

      decimal = BigDecimal(value.to_s)
      # THREE decimal places, because that is what the loan stores:
      # Loan#quantize_variable_rate_schedule rounds every value it keeps to 3.
      # Comparing a 4-decimal reading against a 3-decimal stored rate makes an
      # unchanged rate look changed, and records a new row on EVERY sync
      # (raised by cubic on #213).
      (decimal * 100).round(3)
    rescue ArgumentError, TypeError
      capture("Redbark reported an unparseable rate", value: value.to_s)
      nil
    end

    def apply_rate
      return if reported_rate.nil?

      adopt_rate_type_if_blank

      unless loan.variable_rate_type?
        # A fixed loan's rate does not move, so a bank reporting a different one
        # is a disagreement to surface, not a change to record. Nothing is
        # written -- not the schedule, not `interest_rate`, not `rate_type`.
        if loan.interest_rate.present? && BigDecimal(loan.interest_rate.to_s) != reported_rate
          capture(
            "Redbark reported a rate for a fixed loan; recording nothing",
            loan_id: loan.id, reported: reported_rate.to_s, recorded: loan.interest_rate.to_s
          )
        end
        return
      end

      # First sighting, unchanged rate and the dated change are
      # the loan's rules, shared with Plaid (#223).
      write(loan.variable_rate_update_for(reported_rate, as_of: as_of))
    end

    # `rate_type` is blank on a loan nobody has classified. A bank calling its
    # own product VARIABLE is better evidence than silence, and without this the
    # rate is read and then dropped, since only a variable loan keeps a schedule.
    def adopt_rate_type_if_blank
      return if loan.rate_type.present?
      return unless bank_says_variable?

      write({ rate_type: "variable" })
    end

    def bank_says_variable?
      Array(details[:lendingRates]).any? do |entry|
        entry.is_a?(Hash) && entry[:rateType].to_s.casecmp("VARIABLE").zero?
      end
    end

    # Each filled only when blank: these describe the loan as it was written,
    # and a value already on the record is either the user's or an earlier
    # provider's. `enrich_attributes` skips locked attributes on its own.
    def apply_loan_terms
      terms = details[:loanDetails]
      return unless terms.is_a?(Hash)

      attrs = {}
      attrs[:start_date] = parse_date(terms[:originalStartDate]) if loan.start_date.blank?
      attrs[:initial_balance] = parse_decimal(terms[:originalLoanAmount]) if loan.initial_balance.blank?

      if loan.term_months.blank?
        months = term_months_between(terms[:originalStartDate], terms[:loanEndDate])
        attrs[:term_months] = months if months
      end

      attrs.compact!
      write(attrs) if attrs.any?
    end

    def term_months_between(start_value, end_value)
      from = parse_date(start_value)
      to = parse_date(end_value)
      return nil if from.nil? || to.nil? || to <= from

      months = ((to.year - from.year) * 12) + (to.month - from.month)
      # An end date before the origination day in its month has not reached the
      # anniversary, so that month is not complete (as in
      # PlaidAccount::Liabilities::StudentLoanProcessor#term_months). Counting
      # the calendar month alone overstated the term by one (#303).
      months -= 1 if from + months.months > to
      months.positive? ? months : nil
    end

    # A date is a four-digit CE year. `Date.parse` accepts years the database
    # date column cannot hold ("10000000-01-01", "-4800-01-01"), and writing one
    # raised PG::DatetimeFieldOverflow out of `enrich_attributes`, which -- terms
    # being written before the rate -- stops the rate being applied (#303).
    def parse_date(value)
      return nil if value.blank?

      date = Date.parse(value.to_s)
      return date if date.year.between?(1, 9999)

      capture("Redbark reported a date outside years 1 to 9999; ignoring it", value: value.to_s)
      nil
    rescue Date::Error
      capture("Redbark reported an unparseable date", value: value.to_s)
      nil
    end

    def parse_decimal(value)
      return nil if value.blank?

      amount = BigDecimal(value.to_s)
      # A principal is judged AS THE COLUMN WILL STORE IT: rounded to its scale,
      # positive, and within its precision. `BigDecimal` accepts "0", a negative,
      # "NaN" and "Infinity"; the first three were stored, and `Infinity` -- like
      # any figure past numeric(19,4), or one that rounds out of range -- raised
      # numeric overflow out of `enrich_attributes`, which stops the rate being
      # applied because terms are written before it. A figure that rounds to
      # zero at the column's scale (0.00001) was stored as 0.0 (#303).
      stored = amount.finite? ? amount.round(principal_type.scale) : nil
      return stored if stored&.positive? && stored <= principal_limit

      capture("Redbark reported a principal the loan cannot hold; ignoring it", value: value.to_s)
      nil
    rescue ArgumentError, TypeError
      nil
    end

    def principal_type
      Loan.type_for_attribute("initial_balance")
    end

    # The largest figure the column holds, derived from it rather than written
    # out: 10^(precision - scale) less one unit at the column's scale.
    def principal_limit
      BigDecimal(10)**(principal_type.precision - principal_type.scale) - BigDecimal(10)**-principal_type.scale
    end

    # Every write goes through Loan#enrich_reporting_refusal, shared with Plaid
    # and the record-loan-rate-change rule action: it skips locked attributes,
    # records provenance as a DataEnrichment, and turns a value the model
    # refuses -- a rate outside 0..100, say -- into returned messages instead
    # of an exception that would take the sync with it.
    #
    # It also puts a refused loan back the way it was found. That matters here
    # in particular: terms are applied before the rate, so a bank reporting an
    # absurd `loanEndDate` would otherwise leave an out-of-range `term_months`
    # assigned, the rate write would then be refused for the term rather than
    # for the rate, and the loan would lose a rate change it had every right to
    # (raised by CodeRabbit on #213).
    #
    # A lock doing its job, or a value already held, is not a refusal and logs
    # nothing (rows 3 and 5).
    def write(attrs)
      messages = loan.enrich_reporting_refusal(attrs, source: SOURCE)
      return if messages.nil?

      capture(
        "Redbark loan detail refused by the model",
        loan_id: loan.id,
        attributes: attrs.keys.map(&:to_s),
        errors: messages
      )
    end

    def capture(message, **metadata)
      DebugLogEntry.capture(
        category: "provider_sync",
        level: "warn",
        message: message,
        source: self.class.name,
        provider_key: "redbark",
        family: redbark_account.redbark_item&.family,
        metadata: metadata.merge(redbark_account_id: redbark_account.id)
      )
      Rails.logger.warn "RedbarkAccount::LoanDetailsProcessor - #{message}"
    end
end
