# frozen_string_literal: true

# Fills a credit card's blank APR from the product details the bank publishes
# through `GET /v1/account-details`.
#
# FILL-BLANK ONLY, unlike Plaid, which writes the APR on every sync. Plaid's
# figure is the issuer's for this account; Redbark's `lendingRates` describe the
# PRODUCT. A value already on the card -- typed, imported or restored -- is at
# least as good evidence as a product sheet, so this only fills a gap.
#
# The annual fee is deliberately not read: `fees` publishes the product's
# ceiling ("The Annual Fee that may apply is up to $190"), not what this
# account is charged.
#
# `lendingRate` is not read. What it means for a card is documented nowhere
# this code can cite, and it is null on the one real card payload seen. The
# PURCHASE entries in `lendingRates` are the rate that applies to spending.
class RedbarkAccount::CreditCardDetailsProcessor
  SOURCE = "redbark"

  attr_reader :redbark_account, :as_of

  def initialize(redbark_account, as_of:)
    @redbark_account = redbark_account
    @as_of = as_of
  end

  def process
    return unless card
    return if details.blank?
    return unless details_fetched_this_sync?
    return if card.apr.present?

    rate = purchase_rate
    write(apr: rate) if rate
  end

  private
    # Same gate, for the same reason, as LoanDetailsProcessor: a payload this
    # sync did not refresh is a previous answer, not a current one.
    def details_fetched_this_sync?
      fetched_at = redbark_account.account_details_fetched_at
      return false if fetched_at.blank?

      redbark_account.redbark_item.family.local_date(fetched_at) == as_of.to_date
    end

    def card
      return @card if defined?(@card)

      account = redbark_account.current_account
      @card = account&.accountable_type == "CreditCard" ? account.accountable : nil
    end

    def details
      @details ||= redbark_account.raw_account_details_payload&.deep_symbolize_keys || {}
    end

    # Banks list the purchase rate more than once -- Bankwest repeats it as
    # the balance transfer rate -- so agreement is judged on distinct values.
    # A tiered entry is several rates in one, keyed to a balance the payload
    # does not give, so it is left out rather than allowed to disagree.
    def purchase_rate
      entries = Array(details[:lendingRates]).select do |entry|
        entry.is_a?(Hash) &&
          entry[:rateType].to_s.casecmp("PURCHASE").zero? &&
          Array(entry[:tiers]).empty?
      end

      values = entries.map { |entry| parse_decimal(entry[:rate]) }
      return nil if values.empty? || values.any?(&:nil?)

      distinct = values.uniq
      if distinct.size > 1
        capture("Redbark reported several purchase rates for a card; recording none", rates: distinct.map(&:to_s))
        return nil
      end

      to_percentage(distinct.first)
    end

    # The API reports fractions: "0.1999" is 19.99%. `credit_cards.apr` is a
    # percentage with two decimal places.
    def to_percentage(decimal)
      rate = decimal * 100
      return rate.round(2) if rate.between?(0, 100)

      capture("Redbark reported a card rate outside 0..100%; ignoring it", value: decimal.to_s)
      nil
    end

    def parse_decimal(value)
      return nil if value.blank?

      decimal = BigDecimal(value.to_s)
      decimal if decimal.finite?
    rescue ArgumentError, TypeError
      capture("Redbark reported an unparseable card rate", value: value.to_s)
      nil
    end

    # Through Enrichable, as the loan processor writes: locked attributes are
    # skipped and provenance is recorded. A refusal is rolled back and logged
    # rather than raised, so it cannot fail the sync.
    def write(attrs)
      ActiveRecord::Base.transaction do
        card.enrich_attributes(attrs, source: SOURCE)
        raise ActiveRecord::Rollback if card.errors.any?
      end
      return if card.errors.empty?

      capture(
        "Redbark card detail refused by the model",
        credit_card_id: card.id,
        attributes: attrs.keys.map(&:to_s),
        errors: card.errors.full_messages
      )
      card.restore_attributes(attrs.keys.map(&:to_s))
      card.errors.clear
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
    end
end
