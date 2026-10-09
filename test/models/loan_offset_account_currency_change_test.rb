require "test_helper"

# #328: an offset link is judged on currency only when it is created or
# resubmitted, so a later currency change on either side used to leave a
# cross-currency link behind, and the loan subtracted the foreign balance at
# face value.
class LoanOffsetAccountCurrencyChangeTest < ActiveSupport::TestCase
  setup do
    @loan = accounts(:loan).loan
    @offset = @loan.account.family.accounts.create!(
      name: "Offset", balance: 100_000, currency: "USD", accountable: Depository.new
    )
    @offset.auto_share_with_family!
    @loan.update!(rate_type: "variable", start_date: 2.years.ago.to_date, offset_account_ids: [ @offset.id ])
    # A forthcoming change, so the rate-change table has a row to price.
    @loan.add_variable_rate_change(Date.current + 2.months, 5.93)
    assert_equal [ @offset.id ], @loan.reload.offset_accounts.pluck(:id), "precondition"
  end

  # --- removing the link ------------------------------------------------------

  test "changing an offset account's currency removes its link and records it" do
    loan = Loan.find(@loan.id)
    assert_equal BigDecimal("400000"), loan.interest_bearing_balance.amount, "precondition: the offset counts"

    assert_difference -> { LoanOffsetAccount.count } => -1, -> { DebugLogEntry.where(category: "loan_offset").count } => 1 do
      Account.find(@offset.id).update!(currency: "EUR")
    end

    assert_empty Loan.find(@loan.id).offset_accounts
    assert_equal BigDecimal("500000"), Loan.find(@loan.id).interest_bearing_balance.amount

    entry = DebugLogEntry.where(category: "loan_offset").last
    assert_equal @loan.account.family_id, entry.family_id
    assert_equal @loan.id, entry.metadata["loan_id"]
    assert_equal @offset.id, entry.metadata["offset_account_id"]
    assert_equal "EUR", entry.metadata["offset_currency"]
    assert_equal "USD", entry.metadata["loan_currency"]
  end

  # The shape a provider sync uses: the account's currency, no
  # accountable_attributes.
  test "changing the loan account's currency removes its mismatched links" do
    assert_difference -> { LoanOffsetAccount.count }, -1 do
      Account.find(@loan.account.id).update!(currency: "EUR")
    end

    assert_empty Loan.find(@loan.id).offset_accounts
  end

  # The memoised projection rebuilds when its signature changes, so a loan
  # already in memory reflects the removal without being reloaded.
  test "the removal reaches a loan instance that is already loaded" do
    projection_before = @loan.payoff_projection.total_interest

    Account.find(@offset.id).update!(currency: "EUR")

    assert_not_equal projection_before, @loan.payoff_projection.total_interest
  end

  # A stranded link that survives (no hook ran) must still stop counting on a
  # loan already in memory: the memoised projection's signature has to see
  # the currency, not only the offset ids and balances.
  test "a loaded loan's projection drops an offset stranded without the hook" do
    projection_before = @loan.payoff_projection.total_interest

    @offset.update_columns(currency: "EUR")

    assert_equal [ @offset.id ], @loan.loan_offset_accounts.pluck(:account_id), "precondition: the link survives"
    assert_equal Loan.find(@loan.id).payoff_projection.total_interest, @loan.payoff_projection.total_interest
    assert_not_equal projection_before, @loan.payoff_projection.total_interest
  end

  # Already held before #328: amortization_schedule_signature carries the loan
  # account's currency. Pinned here because the reader filter depends on it.
  test "a loaded loan's projection drops offsets stranded by its own currency" do
    projection_before = @loan.payoff_projection.total_interest

    @loan.account.update_columns(currency: "EUR")

    assert_equal [ @offset.id ], @loan.loan_offset_accounts.pluck(:account_id), "precondition: the link survives"
    assert_not_equal projection_before, @loan.payoff_projection.total_interest
  end

  # --- what must not change ---------------------------------------------------

  test "an update that leaves the currency alone keeps the same link and logs nothing" do
    ids = @loan.loan_offset_accounts.pluck(:id)

    assert_no_difference -> { DebugLogEntry.where(category: "loan_offset").count } do
      Account.find(@offset.id).update!(name: "Renamed offset", balance: 90_000)
      Account.find(@offset.id).update!(currency: "USD")
    end

    assert_equal ids, @loan.loan_offset_accounts.pluck(:id)
  end

  test "another loan's matching link is untouched" do
    other_offset = @loan.account.family.accounts.create!(
      name: "Other offset", balance: 5_000, currency: "USD", accountable: Depository.new
    )
    other_offset.auto_share_with_family!
    other_loan_account = @loan.account.family.accounts.create!(
      name: "Second mortgage", balance: 200_000, currency: "USD",
      accountable: Loan.new(interest_rate: 4, term_months: 240, rate_type: "variable")
    )
    other_loan_account.auto_share_with_family!
    other_loan = other_loan_account.loan
    other_loan.update!(offset_account_ids: [ other_offset.id ])
    kept = other_loan.loan_offset_accounts.pluck(:id)

    Account.find(@offset.id).update!(currency: "EUR")

    assert_equal kept, other_loan.loan_offset_accounts.pluck(:id)
  end

  test "a rolled-back currency change keeps the link" do
    Account.transaction do
      Account.find(@offset.id).update!(currency: "EUR")
      raise ActiveRecord::Rollback
    end

    assert_equal "USD", @offset.reload.currency
    assert_equal [ @offset.id ], Loan.find(@loan.id).offset_accounts.pluck(:id)
  end

  test "a failed account save removes nothing" do
    account = Account.find(@offset.id)

    assert_not account.update(currency: "EUR", name: "")
    assert_equal [ @offset.id ], Loan.find(@loan.id).offset_accounts.pluck(:id)
  end

  # Strand the link first, bypassing the callback, then move the offset into
  # the loan's new currency: the link matches again and must stay. This is what
  # separates comparing currencies from destroying every link the account
  # touches, which is what the sharing path does.
  test "a currency change that brings a link back into line keeps it" do
    @loan.account.update_columns(currency: "EUR")
    ids = @loan.loan_offset_accounts.pluck(:id)

    Account.find(@offset.id).update!(currency: "EUR")

    assert_equal ids, @loan.loan_offset_accounts.pluck(:id)
  end

  test "a balance-only update leaves an already stranded link alone" do
    @offset.update_columns(currency: "EUR")
    ids = @loan.loan_offset_accounts.pluck(:id)

    Account.find(@offset.id).update!(balance: 95_000)

    assert_equal ids, @loan.loan_offset_accounts.pluck(:id)
  end

  # --- a stranded link never reaches a figure -----------------------------------
  #
  # Each reader is compared with the same loan with no link at all, and with
  # the offset back in the loan's currency, so the offset demonstrably matters
  # and the stranded one demonstrably does not.

  test "a stranded offset is not counted by any balance reader" do
    assert_stranded_offset_ignored
  end

  # With a matching offset beside it, the readers that bail out early when a
  # loan has no countable offset run their full path, so the stranded one has
  # to be filtered where the balances are summed, not only at the guard.
  test "a stranded offset is not counted beside a matching one" do
    other = @loan.account.family.accounts.create!(
      name: "Second offset", balance: 40_000, currency: "USD", accountable: Depository.new
    )
    other.auto_share_with_family!
    @loan.update!(offset_account_ids: [ @offset.id, other.id ])

    assert_stranded_offset_ignored
  end

  private

    # Readings with @offset matching, then stranded, then unlinked (any other
    # link kept): stranded must equal unlinked, and both must differ from
    # matching so the offset demonstrably matters.
    def assert_stranded_offset_ignored
      matching = readings(Loan.find(@loan.id))

      @offset.update_columns(currency: "EUR")
      stranded = readings(Loan.find(@loan.id))

      @loan.loan_offset_accounts.where(account_id: @offset.id).delete_all
      unlinked = readings(Loan.find(@loan.id))

      unlinked.each_key do |reader|
        assert_equal unlinked[reader], stranded[reader], "#{reader} counted a stranded offset"
        next if reader == :countable_offsets && unlinked[reader] == matching[reader]

        assert_not_equal unlinked[reader], matching[reader], "#{reader} ignores a matching offset, so the comparison proves nothing"
      end
    end

    def readings(loan)
      today = Date.current
      {
        interest_bearing_balance: loan.interest_bearing_balance.amount,
        countable_offsets: loan.countable_offset_accounts.exists?,
        offset_change_points: Loan::OffsetResolver.new(loan).change_points(today, today + 30),
        # UI::Loan::RateChangeTable left this list in #392: it reads the
        # contracted schedule, which no offset reaches.
        projection_total_interest: Loan::PayoffProjection.new(loan, as_of: today).total_interest
      }
    end
end
