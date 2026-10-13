require "test_helper"

class LoanOffsetAccountTest < ActiveSupport::TestCase
  setup do
    @loan = accounts(:loan).loan
    @offset = @loan.account.family.accounts.create!(
      name: "Test offset", balance: 0, currency: "USD", accountable: Depository.new
    )
  end

  test "links only asset accounts in the same currency and family" do
    link = LoanOffsetAccount.new(loan: @loan, account: @offset)
    assert_predicate link, :valid?

    liability_link = LoanOffsetAccount.new(loan: @loan, account: accounts(:credit_card))
    assert_not liability_link.valid?
    assert_includes liability_link.errors[:account],
      "must be an asset account"
  end

  test "eligible accounts include valid existing links but exclude invalid ones" do
    family = @loan.account.family
    viewer = users(:family_admin)
    wrong_currency = family.accounts.create!(
      name: "Wrong currency offset", balance: 100, currency: "EUR", accountable: Depository.new
    )
    liability = family.accounts.create!(
      name: "Liability offset", balance: 100, currency: "USD", accountable: CreditCard.new
    )
    private_offset = family.accounts.create!(
      name: "Private offset", balance: 100, currency: "USD", owner: viewer, accountable: Depository.new
    )
    @loan.account.share_with!(users(:family_member), permission: "read_only")
    @offset.auto_share_with_family!
    @loan.update!(rate_type: "variable", offset_account_ids: [ @offset.id ])

    LoanOffsetAccount.insert_all!([
      { id: SecureRandom.uuid, loan_id: @loan.id, account_id: wrong_currency.id,
        created_at: Time.current, updated_at: Time.current },
      { id: SecureRandom.uuid, loan_id: @loan.id, account_id: liability.id,
        created_at: Time.current, updated_at: Time.current },
      { id: SecureRandom.uuid, loan_id: @loan.id, account_id: private_offset.id,
        created_at: Time.current, updated_at: Time.current }
    ])

    eligible_ids = LoanOffsetAccount.eligible_accounts_for(@loan, viewer:).map(&:id)

    assert_includes eligible_ids, @offset.id
    assert_not_includes eligible_ids, wrong_currency.id
    assert_not_includes eligible_ids, liability.id
    assert_not_includes eligible_ids, private_offset.id
  end

  test "rejects the loan account and a different currency" do
    self_link = LoanOffsetAccount.new(loan: @loan, account: @loan.account)
    assert_not self_link.valid?
    assert_includes self_link.errors[:account], "cannot be the loan account"

    euro = @loan.account.family.accounts.create!(
      name: "Euro offset", balance: 100, currency: "EUR", accountable: Depository.new
    )
    different_currency = LoanOffsetAccount.new(loan: @loan, account: euro)
    assert_not different_currency.valid?
    assert_includes different_currency.errors[:account], "must use the same currency as the loan"
  end

  test "requires every loan viewer to see the offset account" do
    @loan.account.share_with!(users(:family_member), permission: "read_only")
    link = LoanOffsetAccount.new(loan: @loan, account: @offset)

    assert_not link.valid?
    assert_match "must be visible to every loan viewer", link.errors[:account].join

    @offset.share_with!(users(:family_member), permission: "read_only")
    assert_predicate link, :valid?
  end

  test "sharing changes invalidate an existing offset link" do
    link = @loan.loan_offset_accounts.create!(account: @offset)
    assert_difference -> { LoanOffsetAccount.count }, -1 do
      @loan.account.share_with!(users(:family_member), permission: "read_only")
    end

    assert_not LoanOffsetAccount.exists?(link.id)
  end

  test "revoking offset-account access invalidates an existing link" do
    @offset.share_with!(users(:family_member), permission: "read_only")
    @loan.account.share_with!(users(:family_member), permission: "read_only")
    link = @loan.loan_offset_accounts.create!(account: @offset)

    assert_difference -> { LoanOffsetAccount.count }, -1 do
      @offset.unshare_with!(users(:family_member))
    end

    assert_not LoanOffsetAccount.exists?(link.id)
  end

  test "granting offset-account access preserves an existing link" do
    link = @loan.loan_offset_accounts.create!(account: @offset)

    assert_no_difference -> { LoanOffsetAccount.count } do
      @offset.share_with!(users(:family_member), permission: "read_only")
    end

    assert LoanOffsetAccount.exists?(link.id)
  end

  test "rejects a stale link when a loan viewer loses offset-account access" do
    offset = @loan.account.family.accounts.create!(
      name: "Stale offset", balance: 12_500, currency: "USD", accountable: Depository.new
    )
    viewer = users(:family_member)
    @loan.update!(rate_type: "variable")
    offset.share_with!(viewer, permission: "full_control")
    @loan.account.share_with!(viewer, permission: "full_control")
    @loan.loan_offset_accounts.create!(account: offset)
    offset.unshare_with!(viewer)

    @loan.offset_account_ids = [ offset.id ]

    assert_not LoanOffsetAccount.new(loan: @loan, account: offset).valid?
    assert_not @loan.save
    assert_includes @loan.errors[:offset_account_ids].join, "must be visible to every loan viewer"
  end

  test "clears offset links when the loan becomes non-variable without submitted IDs" do
    @loan.update!(rate_type: "variable", offset_account_ids: [ @offset.id ])
    assert_equal [ @offset.id ], @loan.reload.offset_accounts.pluck(:id)

    @loan.update!(rate_type: "fixed")

    assert_empty @loan.reload.offset_accounts
  end

  test "removing the last link returns the loan to no offset accounts" do
    @loan.loan_offset_accounts.create!(account: @offset)
    assert_equal [ @offset.id ], @loan.reload.offset_accounts.pluck(:id)

    @loan.loan_offset_accounts.delete_all
    assert_empty @loan.reload.offset_accounts
  end

  # --- #290: a loan being created ------------------------------------------
  #
  # `loan.account` is nil while a new loan validates and while its after_save
  # links the offsets, so every check that needs the loan's account used to
  # return early on exactly this path.

  test "a new loan links an offset in its currency that the family can see" do
    family = @loan.account.family
    @offset.auto_share_with_family!

    created = create_loan_on(family, offset: @offset)

    assert_equal [ @offset.id ], created.loan.offset_accounts.pluck(:id)
  end

  test "a new loan refuses an offset in another currency" do
    family = @loan.account.family
    euro = family.accounts.create!(name: "Euro offset", balance: 100, currency: "EUR", accountable: Depository.new)
    euro.auto_share_with_family!

    assert_no_difference [ -> { family.accounts.count }, -> { LoanOffsetAccount.count } ] do
      error = assert_raises(ActiveRecord::RecordInvalid) { create_loan_on(family, offset: euro) }
      assert_match "must use the same currency as the loan", error.message
    end
  end

  # A new account in a family that shares by default is visible to everyone in it
  # the moment it exists, but its shares are written after validation. Judged
  # against its owner alone, a private offset would pass and then be linked from
  # a loan the whole family can see.
  test "a new loan the family will share refuses a private offset" do
    family = @loan.account.family
    assert family.share_all_by_default?, "precondition"
    assert_not_equal [], family.users.where.not(id: @offset.owner_id).to_a, "precondition"
    assert_empty @offset.account_shares, "precondition"

    assert_no_difference [ -> { family.accounts.count }, -> { LoanOffsetAccount.count } ] do
      error = assert_raises(ActiveRecord::RecordInvalid) { create_loan_on(family, offset: @offset) }
      assert_match "must be visible to every loan viewer", error.message
    end
  end

  test "a new loan in a family that does not share by default only needs its owner to see the offset" do
    family = @loan.account.family
    family.update!(default_account_sharing: "private")
    assert_empty @offset.account_shares, "precondition"

    created = create_loan_on(family, offset: @offset)

    assert_equal [ @offset.id ], created.loan.offset_accounts.pluck(:id)
  end

  # `loan.account` is the account as stored, so an edit that changes the
  # currency and the offsets together used to be judged on the old currency.
  # The edit also changes a loan column: a nested save skips a loan whose
  # columns are unchanged, which is a separate defect (see the PR).
  test "an edit that changes the currency is judged on the new currency" do
    account = Account.find(@loan.account.id)
    @offset.auto_share_with_family!
    assert_equal "fixed", @loan.rate_type, "precondition"

    saved = account.update(
      currency: "EUR",
      accountable_attributes: { id: @loan.id, rate_type: "variable", offset_account_ids: [ @offset.id ] }
    )

    assert_not saved
    assert_match "must use the same currency as the loan", account.errors.full_messages.to_sentence
    assert_equal "USD", account.reload.currency
    assert_empty @loan.reload.offset_accounts
  end

  # The same for an offset the loan already has: its existing join row is the
  # one validated, and it read the loan's stored account.
  test "an edit that changes the currency is judged on the new currency for a kept offset" do
    @offset.auto_share_with_family!
    @loan.update!(rate_type: "variable", offset_account_ids: [ @offset.id ])
    assert_equal [ @offset.id ], @loan.reload.offset_accounts.pluck(:id), "precondition"
    account = Account.find(@loan.account.id)

    saved = account.update(
      currency: "EUR",
      accountable_attributes: { id: @loan.id, interest_rate: 4.25, offset_account_ids: [ @offset.id ] }
    )

    assert_not saved
    assert_match "must use the same currency as the loan", account.errors.full_messages.to_sentence
    assert_equal "USD", account.reload.currency
  end

  test "an edit in the loan's own currency still keeps its offset" do
    @offset.auto_share_with_family!
    @loan.update!(rate_type: "variable", offset_account_ids: [ @offset.id ])
    account = Account.find(@loan.account.id)

    saved = account.update(accountable_attributes: { id: @loan.id, interest_rate: 4.25, offset_account_ids: [ @offset.id ] })

    assert saved, account.errors.full_messages.to_sentence
    assert_equal [ @offset.id ], @loan.reload.offset_accounts.pluck(:id)
  end

  # --- #319: offsets are the only thing a nested save changes ----------------

  test "an edit through the account that changes only the offsets links them" do
    @offset.auto_share_with_family!
    @loan.update!(rate_type: "variable")
    account = Account.find(@loan.account.id)

    saved = account.update(accountable_attributes: { id: @loan.id, offset_account_ids: [ @offset.id ] })

    assert saved, account.errors.full_messages.to_sentence
    assert_equal [ @offset.id ], @loan.reload.offset_accounts.pluck(:id)
  end

  # #317's version of this test also changed `interest_rate`, to get the loan
  # validated at all.
  test "an edit that changes the currency and only resubmits a kept offset is judged on the new currency" do
    @offset.auto_share_with_family!
    @loan.update!(rate_type: "variable", offset_account_ids: [ @offset.id ])
    account = Account.find(@loan.account.id)

    saved = account.update(currency: "EUR", accountable_attributes: { id: @loan.id, offset_account_ids: [ @offset.id ] })

    assert_not saved
    assert_match "must use the same currency as the loan", account.errors.full_messages.to_sentence
    assert_equal "USD", account.reload.currency
  end

  # nil means "this save is not about offsets"; an empty list means "remove them
  # all". Only the second may pull the loan into its account's save.
  test "a supplied offset list counts as a change for autosave and an absent one does not" do
    loan = Loan.find(@loan.id)
    assert_not loan.changed_for_autosave?, "precondition"

    loan.offset_account_ids = nil
    assert_not loan.changed_for_autosave?

    loan.offset_account_ids = []
    assert loan.changed_for_autosave?
  end

  test "a nested save with no offset list leaves the loan's links alone" do
    @offset.auto_share_with_family!
    @loan.update!(rate_type: "variable", offset_account_ids: [ @offset.id ])
    link_ids = @loan.loan_offset_accounts.pluck(:id)
    account = Account.find(@loan.account.id)

    saved = account.update(name: "Renamed", accountable_attributes: { id: @loan.id, offset_account_ids: nil })

    assert saved, account.errors.full_messages.to_sentence
    assert_equal link_ids, @loan.reload.loan_offset_accounts.pluck(:id)
  end

  private
    def create_loan_on(family, offset:)
      family.accounts.create_and_sync(
        { name: "New loan", balance: 1_000, currency: "USD", owner: users(:family_admin),
          accountable_type: "Loan",
          accountable_attributes: { rate_type: "variable", offset_account_ids: [ offset.id ] } }
      )
    end
end
