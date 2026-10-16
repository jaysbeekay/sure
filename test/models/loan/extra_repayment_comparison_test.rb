require "test_helper"

class Loan::ExtraRepaymentComparisonTest < ActiveSupport::TestCase
  setup do
    start_date = Date.current
    @account = Account.create!(
      family: families(:dylan_family),
      name: "Comparison Loan",
      balance: 500000,
      currency: "USD",
      accountable: Loan.create!(
        subtype: "mortgage", interest_rate: 3.5, term_months: 360, rate_type: "fixed", start_date: start_date
      )
    )
    @account.entries.create!(
      name: "Starting balance", amount: 500000, currency: "USD", date: start_date,
      entryable: Valuation.new(kind: "opening_anchor")
    )
    @loan = @account.loan
  end

  test "with no amount only the baseline is built" do
    comparison = @loan.extra_repayment_comparison(amount: nil)

    assert_nil comparison.extra
    assert_not comparison.extra_converged?
    assert_nil comparison.months_sooner
    assert_nil comparison.interest_saved
    assert comparison.baseline.converged?, "an on-schedule loan still has its baseline to compare against"
  end

  test "a blank amount is the same as no amount" do
    assert_nil @loan.extra_repayment_comparison(amount: "").extra
  end

  test "with an amount both projections share one as_of and the figures compare them" do
    # Not Date.current: that is also every default, so it would pass with
    # the caller's date dropped on the way down.
    as_of = Date.current + 3.days
    comparison = @loan.extra_repayment_comparison(amount: "200", as_of: as_of)

    assert_equal as_of, comparison.baseline.as_of
    assert_equal as_of, comparison.extra.as_of
    assert comparison.extra_converged?
    assert_equal comparison.baseline.payment_count - comparison.extra.payment_count, comparison.months_sooner
    assert_equal Money.new(comparison.baseline.total_interest.amount - comparison.extra.total_interest.amount, "USD"),
      comparison.interest_saved
  end

  # A loan whose current repayment never clears it has no baseline to chart,
  # so the tab says why instead. What it says depends on the amount: with
  # none, ask for one; with one that clears the loan, say the extra does it;
  # with one that doesn't, say so -- never "enter an amount" once one was.
  test "the non-convergence notice follows the amount entered" do
    loan = non_converging_loan

    assert_equal :enter_amount, loan.extra_repayment_comparison(amount: nil).non_convergence_notice

    cleared = loan.extra_repayment_comparison(amount: "200000")
    assert cleared.extra_converged?, "test setup: this extra should clear the loan"
    assert_equal :cleared_by_extra, cleared.non_convergence_notice

    still_stuck = loan.extra_repayment_comparison(amount: "0.01")
    assert_not still_stuck.extra_converged?, "test setup: a cent should not clear the loan"
    assert_equal :not_cleared_by_extra, still_stuck.non_convergence_notice
  end

  test "a loan the current repayment clears needs no non-convergence notice" do
    assert_nil @loan.extra_repayment_comparison(amount: nil).non_convergence_notice
    assert_nil @loan.extra_repayment_comparison(amount: "200").non_convergence_notice
  end

  private

    # Same construction as Loan::PayoffProjectionTest's iteration-cap case:
    # the payment just covers the first period's interest, so the payoff
    # runs past the projection's cap and it reports no convergence.
    def non_converging_loan
      start_date = Date.current
      account = Account.create!(
        family: families(:dylan_family), name: "Stuck Loan", balance: 100000, currency: "USD",
        accountable: Loan.create!(
          subtype: "mortgage", interest_rate: 5.0, term_months: 12, rate_type: "fixed", start_date: start_date
        )
      )
      account.entries.create!(
        name: "Starting balance", amount: 100000, currency: "USD", date: start_date,
        entryable: Valuation.new(kind: "opening_anchor")
      )
      loan = account.loan.tap(&:ensure_amortization_schedule_current!)
      payment = loan.amortization_schedule.periodic_payment.amount
      threshold = payment / (BigDecimal("5.0") / 100 / 12)
      account.update!(balance: (threshold * BigDecimal("0.995")).round(2))
      loan.reload
      assert_not loan.payoff_projection.converged?, "test setup: the baseline should not converge"
      loan
    end
end
