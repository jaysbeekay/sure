require "test_helper"

class PlaidAccount::Liabilities::StudentLoanProcessorTest < ActiveSupport::TestCase
  setup do
    @plaid_account = plaid_accounts(:one)
    @plaid_account.update!(
      plaid_type: "loan",
      plaid_subtype: "student"
    )

    # Change the underlying accountable to a Loan so the helper method `loan` is available
    @plaid_account.current_account.update!(accountable: Loan.new)
  end

  test "updates loan details including term months from Plaid data" do
    @plaid_account.update!(raw_liabilities_payload: {
      student: {
        interest_rate_percentage: 5.5,
        origination_principal_amount: 20000,
        origination_date: Date.new(2020, 1, 1),
        expected_payoff_date: Date.new(2022, 1, 1)
      }
    })

    processor = PlaidAccount::Liabilities::StudentLoanProcessor.new(@plaid_account)
    processor.process

    loan = @plaid_account.current_account.loan

    assert_equal "fixed", loan.rate_type
    assert_equal 5.5, loan.interest_rate
    assert_equal 20000, loan.initial_balance
    assert_equal 24, loan.term_months
  end

  test "handles missing payoff dates gracefully" do
    @plaid_account.update!(raw_liabilities_payload: {
      student: {
        interest_rate_percentage: 4.8,
        origination_principal_amount: 15000,
        origination_date: Date.new(2021, 6, 1)
        # expected_payoff_date omitted
      }
    })

    processor = PlaidAccount::Liabilities::StudentLoanProcessor.new(@plaid_account)
    processor.process

    loan = @plaid_account.current_account.loan

    assert_nil loan.term_months
    assert_equal 4.8, loan.interest_rate
    assert_equal 15000, loan.initial_balance
  end

  test "does nothing when loan data absent" do
    @plaid_account.update!(raw_liabilities_payload: {})

    processor = PlaidAccount::Liabilities::StudentLoanProcessor.new(@plaid_account)
    processor.process

    loan = @plaid_account.current_account.loan

    assert_nil loan.interest_rate
    assert_nil loan.initial_balance
    assert_nil loan.term_months
  end

  # ------------------------------------------------------------------- #158

  # Row 6, and the worst of the set: this processor sent `rate_type: "fixed"` on
  # EVERY sync, so a loan the user marked variable reverted each time.
  test "a locked rate type is not forced back to fixed" do
    loan = loan_with(rate_type: "variable", interest_rate: 5.0)
    loan.lock_attr!(:rate_type)
    payload("interest_rate_percentage" => 5.0)

    process

    assert_equal "variable", loan.reload.rate_type, "Plaid forced a locked rate type back to fixed"
  end

  # Row 7. Locked and unlocked attributes in one payload: the locks hold and
  # the rest is still written, so the fix is not "refuse the whole write".
  test "locked terms hold while the unlocked ones are still written" do
    loan = loan_with(initial_balance: 50_000, term_months: 120, interest_rate: 5.0)
    loan.lock_attr!(:initial_balance)
    loan.lock_attr!(:term_months)
    payload(
      "interest_rate_percentage" => 6.5,
      "origination_principal_amount" => 90_000,
      "origination_date" => "2020-01-01",
      "expected_payoff_date" => "2040-01-01"
    )

    process

    loan.reload
    assert_equal 50_000, loan.initial_balance.to_i, "a locked original balance was overwritten"
    assert_equal 120, loan.term_months, "a locked term was overwritten"
    assert_equal 6.5, loan.interest_rate.to_f, "the unlocked rate was not written"
  end

  # Row 8. `term_months` is nil without BOTH dates, and nil must not blank a
  # stored term.
  test "a payload missing a payoff date leaves the stored term alone" do
    loan = loan_with(term_months: 120, interest_rate: 5.0)
    payload("interest_rate_percentage" => 5.0, "origination_date" => "2020-01-01")

    process

    assert_equal 120, loan.reload.term_months, "an incomplete pair of dates blanked the stored term"
  end

  # Row 9.
  test "a payload without a rate leaves the stored rate alone" do
    loan = loan_with(interest_rate: 4.5)
    payload("origination_principal_amount" => 90_000)

    process

    assert_equal 4.5, loan.reload.interest_rate.to_f, "an omitted rate blanked the stored one"
    assert_equal 90_000, loan.initial_balance.to_i
  end

  private
    def loan_with(**attrs)
      loan = @plaid_account.current_account.loan
      loan.update!(attrs)
      loan
    end

    def payload(data)
      @plaid_account.update!(raw_liabilities_payload: { student: data })
    end

    def process
      PlaidAccount::Liabilities::StudentLoanProcessor.new(@plaid_account.reload).process
    end
end
