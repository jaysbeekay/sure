require "test_helper"

class Balance::LinkedInvestmentSeriesNormalizerTest < ActiveSupport::TestCase
  test "pending transactions do not establish supported balance history" do
    account = families(:empty).accounts.create!(
      name: "Linked Investment",
      balance: 0,
      currency: "USD",
      accountable: Investment.new
    )
    pending_date = 5.days.ago.to_date
    posted_date = 2.days.ago.to_date

    account.entries.create!(
      date: pending_date,
      name: "Pending Transaction",
      amount: 100,
      currency: "USD",
      source: "plaid",
      entryable: Transaction.new(extra: { "plaid" => { "pending" => true } })
    )
    account.entries.create!(
      date: posted_date,
      name: "Posted Transaction",
      amount: 100,
      currency: "USD",
      source: "plaid",
      entryable: Transaction.new
    )

    start_date = Balance::LinkedInvestmentSeriesNormalizer
      .send(:common_supported_history_start_date, [ account.id ])

    assert_equal posted_date, start_date
  end

  test "trim_to_supported_history drops the points before the common supported start" do
    account = families(:empty).accounts.create!(name: "Linked Investment", balance: 0, currency: "USD", accountable: Investment.new)
    account.entries.create!(date: 3.days.ago.to_date, name: "Deposit", amount: -100, currency: "USD", source: "plaid", entryable: Transaction.new)
    values = (0..5).map do |offset|
      date = 5.days.ago.to_date + offset
      Series::Value.new(date: date, date_formatted: date.to_s, value: Money.new(offset, "USD"), trend: nil)
    end
    series = Series.new(start_date: values.first.date, end_date: values.last.date, interval: "1 day", values: values, favorable_direction: "up")

    trimmed = Balance::LinkedInvestmentSeriesNormalizer.trim_to_supported_history(series, account_ids: [ account.id ])

    assert_equal 3.days.ago.to_date, trimmed.start_date
    assert_equal 4, trimmed.values.size
    assert_equal series.end_date, trimmed.end_date

    # An unlinked account (no sourced entries, no provider holdings) has no
    # supported-history start, so the series is returned untouched.
    manual = families(:empty).accounts.create!(name: "Manual", balance: 0, currency: "USD", accountable: Investment.new)
    assert_same series, Balance::LinkedInvestmentSeriesNormalizer.trim_to_supported_history(series, account_ids: [ manual.id ])
  end
end
