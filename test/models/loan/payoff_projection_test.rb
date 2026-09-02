require "test_helper"

class Loan::PayoffProjectionTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
  end

  # Builds a fixed-rate loan whose original balance is pinned via an explicit
  # opening_anchor valuation (so `Loan#original_balance` stays fixed even
  # after we later mutate `account.balance` to simulate the "current, actual"
  # position). start_date defaults to today so every persisted amortization
  # row is naturally in the future relative to `Date.current`.
  def build_loan(balance:, interest_rate: 3.5, term_months: 360, start_date: Date.current, rate_type: "fixed")
    account = Account.create! \
      family: @family,
      name: "Test Loan #{SecureRandom.hex(4)}",
      balance: balance,
      currency: "USD",
      accountable: Loan.create!(
        subtype: "mortgage",
        interest_rate: interest_rate,
        term_months: term_months,
        rate_type: rate_type,
        start_date: start_date
      )

    account.entries.create!(
      name: "Starting balance",
      amount: balance,
      currency: "USD",
      date: start_date,
      entryable: Valuation.new(kind: "opening_anchor")
    )

    account.loan
  end

  test "matches the original schedule (within a rounding-driven cleanup payment) when the current balance equals the original balance" do
    loan = build_loan(balance: 500000)

    projection = loan.payoff_projection

    # The original schedule forces its (known-in-advance) final payment to
    # exactly clear the balance, adjusting that payment's amount. This
    # projection doesn't know its final period in advance -- it keeps paying
    # the constant level payment and only adjusts once a period's payment
    # would otherwise overshoot -- so an unchanged balance can still trail by
    # one small "cleanup" payment after 360 periods of accumulated monthly
    # rounding. That's a real, tiny artifact of two independently-terminated
    # simulations, not a meaningful difference.
    assert projection.applicable?
    assert projection.months_saved.between?(-1, 0)
    assert projection.interest_saved.abs < 1
  end

  test "projects a sooner payoff and positive interest saved when ahead of schedule" do
    loan = build_loan(balance: 500000)
    loan.account.update!(balance: 450000) # extra $50k paid toward principal

    projection = loan.payoff_projection

    assert projection.applicable?
    assert projection.months_saved > 0
    assert projection.interest_saved > 0
    assert projection.payoff_date < loan.amortization_schedule.payoff_date
    assert_equal loan.amortization_schedule.monthly_payment, projection.monthly_payment
  end

  test "projects a later payoff and negative interest saved when behind schedule" do
    loan = build_loan(balance: 500000)
    loan.account.update!(balance: 550000) # owes more than originally contracted

    projection = loan.payoff_projection

    assert projection.applicable?
    assert projection.months_saved < 0
    assert projection.interest_saved < 0
  end

  test "not applicable when the current balance is fully paid off" do
    loan = build_loan(balance: 500000)
    loan.account.update!(balance: 0)

    projection = loan.payoff_projection

    assert_not projection.applicable?
    assert_nil projection.payoff_date
    assert_nil projection.months_saved
    assert_nil projection.interest_saved
    assert_equal [], projection.payments
  end

  test "not applicable for variable rate loans" do
    loan = build_loan(balance: 500000, rate_type: "variable")

    assert_not loan.payoff_projection.applicable?
  end

  test "not applicable when the fixed payment no longer covers interest at the current balance" do
    loan = build_loan(balance: 500000)
    # Monthly payment (~$2245.22) no longer covers interest once the balance
    # is high enough: 2245.22 / (3.5% / 12) ~= 769,790.
    loan.account.update!(balance: 800000)

    assert_not loan.payoff_projection.applicable?
  end

  test "all persisted original payments are in the future for a loan starting today" do
    loan = build_loan(balance: 500000)
    loan.payoff_projection # triggers ensure_amortization_schedule_current!

    assert_equal 360, loan.amortizations.where("payment_date > ?", Date.current).count
  end

  test "zero interest rate projects a straight-line payoff" do
    loan = build_loan(balance: 120000, interest_rate: 0, term_months: 120)
    loan.account.update!(balance: 100000)

    projection = loan.payoff_projection

    assert projection.applicable?
    assert projection.months_saved > 0
    assert_equal BigDecimal("0"), projection.total_interest.amount
  end
end
