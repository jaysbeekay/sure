# frozen_string_literal: true

require "test_helper"

# A Redbark-linked card's APR, read from the product details the bank publishes
# through `/v1/account-details`. Rates there are FRACTIONS as strings: "0.1999"
# is 19.99%.
#
# The fixtures mirror a real Bankwest More Platinum payload: the purchase rate
# is listed twice (once as the balance transfer rate) beside a cash advance
# rate.
class RedbarkAccount::CreditCardDetailsProcessorTest < ActiveSupport::TestCase
  setup do
    @redbark_account = redbark_accounts(:savings_account)
    @family = @redbark_account.redbark_item.family
    @as_of = Date.new(2026, 11, 20)

    @account = @family.accounts.create!(
      name: "Credit card", balance: 1_000, currency: "AUD", accountable: CreditCard.new
    )
    @card = @account.accountable

    @redbark_account.ensure_account_provider!(@account)
    @redbark_account.reload
  end

  # --- APR ---------------------------------------------------------------

  test "a blank APR is filled from the purchase rate the bank lists twice" do
    detail lendingRates: [
      purchase("0.1999"),
      purchase("0.1999", additionalInfo: "Standard balance transfer rate."),
      rate("CASH_ADVANCE", "0.2199")
    ]

    process

    assert_equal BigDecimal("19.99"), @card.reload.apr
  end

  test "two spellings of the same purchase rate are one rate" do
    detail lendingRates: [ purchase("0.1999"), purchase("0.19990") ]

    process

    assert_equal BigDecimal("19.99"), @card.reload.apr,
                 "the same rate written with a trailing zero was read as a disagreement"
  end

  test "the rate is rounded to the column's two places, not truncated" do
    detail lendingRates: [ purchase("0.19999") ]

    process

    assert_equal BigDecimal("20.00"), @card.reload.apr
  end

  test "a tiered purchase entry is ignored, not outvoted" do
    detail lendingRates: [
      purchase("0.1999"),
      purchase("0.2499", tiers: [ { name: "Band 1", minimumValue: "0" } ])
    ]

    process

    assert_equal BigDecimal("19.99"), @card.reload.apr
  end

  test "a cash advance rate alone is not an APR" do
    detail lendingRates: [ rate("CASH_ADVANCE", "0.2199") ]

    process

    assert_nil @card.reload.apr
  end

  # lendingRate's meaning for a card is undocumented; only PURCHASE is read.
  test "a headline lendingRate with no purchase entry fills nothing" do
    detail lendingRate: "0.1499", lendingRates: []

    process

    assert_nil @card.reload.apr
  end

  test "purchase rates that disagree record nothing and say so" do
    detail lendingRates: [ purchase("0.1999"), purchase("0.0999") ]

    assert_difference -> { DebugLogEntry.where(source: RedbarkAccount::CreditCardDetailsProcessor.name).count }, 1 do
      process
    end

    assert_nil @card.reload.apr
  end

  test "a rate outside 0..100 percent is ignored" do
    detail lendingRates: [ purchase("1.5") ]

    process

    assert_nil @card.reload.apr
  end

  test "an unparseable rate is ignored" do
    detail lendingRates: [ purchase("n/a") ]

    process

    assert_nil @card.reload.apr
  end

  # --- Annual fee --------------------------------------------------------

  # The published fee is the product's ceiling ("up to $190"), not what this
  # account is charged, so it is never copied onto the card.
  test "a published yearly fee does not fill a blank annual fee" do
    detail lendingRates: [ purchase("0.1999") ], fees: [ fee("PERIODIC", "190.00", "P1Y", name: "Annual Fee") ]

    process

    @card.reload
    assert_equal BigDecimal("19.99"), @card.apr
    assert_nil @card.annual_fee
  end

  # --- What is never written ---------------------------------------------

  test "an APR already on the card is kept" do
    @card.update!(apr: 12.5)
    detail lendingRates: [ purchase("0.1999") ]

    assert_no_difference -> { DataEnrichment.where(enrichable: @card).count } do
      process
    end

    assert_equal BigDecimal("12.5"), @card.reload.apr
  end

  test "a locked blank APR stays blank" do
    @card.lock_attr!(:apr)
    detail lendingRates: [ purchase("0.1999") ]

    process

    assert_nil @card.reload.apr, "a locked APR was written by the provider"
  end

  test "a snapshot not fetched this sync is not acted on" do
    detail lendingRates: [ purchase("0.1999") ], fetched_at: (@as_of - 1).in_time_zone

    process

    assert_nil @card.reload.apr
  end

  test "a card with no details is left alone" do
    process

    assert_nil @card.reload.apr
  end

  test "an account that is not a credit card is left alone" do
    loan_account = @family.accounts.create!(
      name: "Loan", balance: 1_000, currency: "AUD", accountable: Loan.new
    )
    @redbark_account.ensure_account_provider!(loan_account)
    detail lendingRates: [ purchase("0.1999") ]

    assert_no_difference -> { DataEnrichment.count } do
      process
    end
    assert_nil @card.reload.apr
  end

  test "the write is attributed to redbark" do
    detail lendingRates: [ purchase("0.1999") ]

    process

    assert_equal [ "redbark" ], DataEnrichment.where(enrichable: @card, attribute_name: "apr").pluck(:source)
  end

  private
    def detail(fetched_at: @as_of.in_time_zone, **payload)
      @redbark_account.update!(
        raw_account_details_payload: { "accountId" => @redbark_account.redbark_account_id }.merge(
          payload.deep_stringify_keys
        ),
        account_details_fetched_at: fetched_at
      )
      @redbark_account.reload
    end

    def process
      RedbarkAccount::CreditCardDetailsProcessor.new(@redbark_account, as_of: @as_of).process
    end

    def purchase(value, **extra)
      rate("PURCHASE", value, **extra)
    end

    def rate(type, value, **extra)
      { rateType: type, rate: value, calculationFrequency: "P1D", applicationFrequency: "P1M" }.merge(extra)
    end

    def fee(type, amount, additional_value, name: "Fee")
      { name: name, feeType: type, amount: amount, currency: "AUD", additionalValue: additional_value }
    end
end
