require "test_helper"

class Security::Price::ImportWindowsTest < ActiveSupport::TestCase
  setup do
    Security::Price.delete_all
    Trade.delete_all
    Holding.delete_all
    Security.delete_all
  end

  test "uses the last positive holding for a closed position without trades" do
    family = Family.create!(name: "Smith", currency: "USD")
    account = family.accounts.create!(name: "Brokerage", currency: "USD", balance: 0, accountable: Investment.new)
    security = Security.create!(ticker: "HIST", exchange_operating_mic: "XNAS")
    held_date = 10.days.ago.to_date

    account.holdings.create!(security: security, date: held_date, qty: 2, price: 100, amount: 200, currency: "USD")
    account.holdings.create!(security: security, date: Date.current, qty: 0, price: 100, amount: 0, currency: "USD")

    window = Security::Price::ImportWindows.new(account).to_h.fetch(security.id)

    assert_equal held_date, window.start_date
    assert_equal held_date, window.end_date
  end

  test "recognizes a new manual buy before holdings are rematerialized" do
    family = Family.create!(name: "Smith", currency: "USD")
    account = family.accounts.create!(name: "Brokerage", currency: "USD", balance: 0, accountable: Investment.new)
    security = Security.create!(ticker: "REOPEN", exchange_operating_mic: "XNAS")
    buy_date = 20.days.ago.to_date

    account.entries.create!(name: "Buy", date: buy_date, amount: 100, currency: "USD",
                            entryable: Trade.new(security: security, qty: 1, price: 100, currency: "USD", investment_activity_label: "Buy"))
    account.entries.create!(name: "Sell", date: 10.days.ago.to_date, amount: 110, currency: "USD",
                            entryable: Trade.new(security: security, qty: -1, price: 110, currency: "USD", investment_activity_label: "Sell"))
    account.holdings.create!(security: security, date: Date.current, qty: 0, price: 110, amount: 0, currency: "USD")

    account.entries.create!(name: "Rebuy", date: 2.days.ago.to_date, amount: 120, currency: "USD",
                            entryable: Trade.new(security: security, qty: 1, price: 120, currency: "USD", investment_activity_label: "Buy"))

    window = Security::Price::ImportWindows.new(account).to_h.fetch(security.id)

    assert_equal buy_date, window.start_date
    assert_equal Date.current, window.end_date
  end

  test "recognizes a buy after a closed provider snapshot" do
    family = Family.create!(name: "Smith", currency: "USD")
    account = family.accounts.create!(name: "Brokerage", currency: "USD", balance: 0, accountable: Investment.new)
    security = Security.create!(ticker: "LINKED", exchange_operating_mic: "XNAS")
    provider_item = family.coinstats_items.create!(name: "CoinStats", api_key: "test-key")
    provider_account = provider_item.coinstats_accounts.create!(name: "Provider", currency: "USD")
    account_provider = AccountProvider.create!(account: account, provider: provider_account)
    first_held_date = 20.days.ago.to_date
    sold_date = 10.days.ago.to_date

    account.holdings.create!(security: security, date: first_held_date, qty: 1, price: 100, amount: 100,
                             currency: "USD", account_provider: account_provider)
    account.holdings.create!(security: security, date: sold_date, qty: 0, price: 110, amount: 0,
                             currency: "USD", account_provider: account_provider)
    account.holdings.create!(security: security, date: Date.current, qty: 0, price: 110, amount: 0, currency: "USD")

    account.entries.create!(name: "Buy", date: 2.days.ago.to_date, amount: 120, currency: "USD",
                            entryable: Trade.new(security: security, qty: 1, price: 120, currency: "USD", investment_activity_label: "Buy"))

    window = Security::Price::ImportWindows.new(account).to_h.fetch(security.id)

    assert_equal first_held_date, window.start_date
    assert_equal Date.current, window.end_date
  end
end
