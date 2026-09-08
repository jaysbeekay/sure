require "test_helper"

class LoanTest < ActiveSupport::TestCase
  test "rejects invalid subtype" do
    loan = Loan.new(subtype: "invalid")

    assert_not loan.valid?
    assert_includes loan.errors[:subtype], "is not included in the list"
  end

  test "calculates correct monthly payment for fixed rate loan" do
    loan_account = Account.create! \
      family: families(:dylan_family),
      name: "Mortgage Loan",
      balance: 500000,
      currency: "USD",
      accountable: Loan.create!(
        subtype: "mortgage",
        interest_rate: 3.5,
        term_months: 360,
        rate_type: "fixed"
      )

    assert_equal BigDecimal("2245.22"), loan_account.loan.monthly_payment.amount
  end

  test "monthly payment is zero for a non-positive term" do
    loan_account = Account.create! \
      family: families(:dylan_family),
      name: "Backwards Loan",
      balance: 500000,
      currency: "USD",
      accountable: Loan.create!(
        subtype: "mortgage",
        interest_rate: 3.5,
        term_months: -360,
        rate_type: "fixed"
      )

    assert_equal 0, loan_account.loan.monthly_payment.amount
    assert_not loan_account.loan.amortizable?
  end

  # Reversed in part by #104: a variable loan now has a schedule. It still has
  # no single monthly payment, because it does not have one -- quoting the
  # payment it opened with would present a stale figure as a current one.
  test "variable rate loans have a schedule but no single monthly payment" do
    account = Account.create! \
      family: families(:dylan_family),
      name: "Variable Mortgage",
      balance: 500000,
      currency: "USD",
      accountable: Loan.create!(subtype: "mortgage", interest_rate: 3.5, term_months: 360, rate_type: "variable")

    assert account.loan.amortizable?
    assert_not_nil account.loan.amortization_schedule
    assert_nil account.loan.monthly_payment
  end

  test "a loan with no account is not amortizable rather than raising" do
    assert_not Loan.new(interest_rate: 3.5, term_months: 360, rate_type: "variable").amortizable?
    assert_not Loan.new(interest_rate: 3.5, term_months: 360, rate_type: "fixed").amortizable?
  end
end
