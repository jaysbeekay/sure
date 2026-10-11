require "test_helper"

class AccountSimplefinCreationTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @item = SimplefinItem.create!(family: @family, name: "SF Conn", access_url: "https://example.com/access")
  end

  test "requires explicit account_type at creation" do
    sfa = SimplefinAccount.create!(
      simplefin_item: @item,
      name: "Brokerage",
      account_id: "acct_1",
      currency: "USD",
      account_type: "investment",
      current_balance: 1000
    )

    assert_raises(ArgumentError) do
      Account.create_from_simplefin_account(sfa, nil)
    end
  end

  test "uses provided account_type without inference" do
    sfa = SimplefinAccount.create!(
      simplefin_item: @item,
      name: "My Loan",
      account_id: "acct_2",
      currency: "USD",
      account_type: "loan",
      current_balance: -5000
    )

    account = Account.create_from_simplefin_account(sfa, "Loan")

    assert_equal "Loan", account.accountable_type
  end

  # #188: no provider transmits a day-count basis, so a synced loan takes the
  # column default for new loans, as a hand-made one does.
  test "a loan created from SimpleFIN starts on thirty_360" do
    sfa = SimplefinAccount.create!(
      simplefin_item: @item, name: "Synced Loan", account_id: "acct_dc", currency: "USD",
      account_type: "loan", current_balance: -5000
    )

    account = Account.create_from_simplefin_account(sfa, "Loan")

    assert_equal "thirty_360", account.loan.reload.day_count_convention
  end
end
