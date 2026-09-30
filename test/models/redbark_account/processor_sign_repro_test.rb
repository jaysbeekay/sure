# frozen_string_literal: true

require "test_helper"

# Reproduction for we-promise/sure#3747 -- Redbark liability balance sign.
#
# RedbarkAccount::Processor#update_account_balance negates current_balance for
# every CreditCard and Loan. That is only right when the upstream source uses the
# CDR convention (negative = owed), which Redbark's own sample response shows
# for a credit card ("-842.15"). Accounts Redbark sources from Plaid follow
# Plaid's convention instead: for credit and loan accounts a POSITIVE current
# balance is the amount owed (https://plaid.com/docs/api/accounts/). The reporter
# observed exactly that for US cards: +19,902.38 from Redbark, -19,902.38 in Sure.
#
# Tests marked [BUG] assert the correct behaviour and FAIL on current main.
# Tests marked [CONTROL] assert the CDR path, which is correct today, and PASS.
class RedbarkAccount::ProcessorSignReproTest < ActiveSupport::TestCase
  setup do
    @redbark_item = redbark_items(:one)
    @family = @redbark_item.family
    @currency = @family.currency
  end

  test "[BUG] positive (Plaid-convention) credit card balance is stored as a positive amount owed" do
    card, redbark_account = link(CreditCard, provider: "plaid", type: "credit-card", balance: "19902.38")

    RedbarkAccount::Processor.new(redbark_account).process

    assert_equal BigDecimal("19902.38"), card.reload.balance,
      "Card owing 19,902.38 was stored as #{card.balance.to_s('F')}"
  end

  test "[BUG] an inverted card balance overstates net worth by twice the amount owed" do
    card, redbark_account = link(CreditCard, provider: "plaid", type: "credit-card", balance: "19902.38")
    before = BalanceSheet.new(@family).net_worth

    RedbarkAccount::Processor.new(redbark_account).process
    after = BalanceSheet.new(@family).net_worth

    assert_equal BigDecimal("-19902.38"), after - before,
      "Net worth moved by #{(after - before).to_s('F')} after syncing a card that owes 19,902.38 " \
      "(liability balance stored as #{card.reload.balance.to_s('F')})"
  end

  test "[BUG] a manual correction of the card balance is reverted by the next sync" do
    card, redbark_account = link(CreditCard, provider: "plaid", type: "credit-card", balance: "549.51")
    RedbarkAccount::Processor.new(redbark_account).process
    card.reload.update!(balance: BigDecimal("549.51")) # user fixes it by hand

    RedbarkAccount::Processor.new(redbark_account).process

    assert_equal BigDecimal("549.51"), card.reload.balance,
      "Manual correction to 549.51 was overwritten with #{card.balance.to_s('F')}"
  end

  test "[CONTROL] negative (CDR-convention) credit card balance is stored as a positive amount owed" do
    card, redbark_account = link(CreditCard, provider: "fiskil", type: "credit-card", balance: "-842.15")

    RedbarkAccount::Processor.new(redbark_account).process

    assert_equal BigDecimal("842.15"), card.reload.balance
  end

  test "[CONTROL] negative (CDR-convention) loan balance is stored as a positive amount owed" do
    loan, redbark_account = link(Loan, provider: "fiskil", type: "loan", balance: "-997672.00")

    RedbarkAccount::Processor.new(redbark_account).process

    assert_equal BigDecimal("997672.00"), loan.reload.balance
  end

  private

    def link(accountable_class, provider:, type:, balance:)
      account = @family.accounts.create!(
        name: "Repro #{type} (#{provider})",
        balance: 0,
        currency: @currency,
        accountable: accountable_class.new
      )

      redbark_account = @redbark_item.redbark_accounts.create!(
        redbark_account_id: "rb_repro_#{SecureRandom.hex(4)}",
        name: account.name,
        currency: @currency,
        provider: provider,
        account_type: type,
        current_balance: BigDecimal(balance)
      )
      redbark_account.ensure_account_provider!(account)
      redbark_account.reload

      [ account, redbark_account ]
    end
end
