require "test_helper"

class Loan::PayoffProjectionTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @today = Date.new(2027, 1, 15)
  end

  test "a loan exactly on contract projects the schedule it is already on" do
    loan = build_loan(term_months: 24)
    on_contract = scheduled_balance_at(loan, @today)
    loan.account.update!(balance: on_contract)

    projection = loan.payoff_projection(as_of: @today)

    assert projection.applicable?
    assert projection.converged?
    assert_equal loan.amortization_schedule.payoff_date, projection.payoff_date
    assert_equal 0, projection.months_saved
  end

  test "an overpaid loan finishes early and pays less interest" do
    loan = build_loan(term_months: 24)
    loan.account.update!(balance: scheduled_balance_at(loan, @today) - 50_000)

    projection = loan.payoff_projection(as_of: @today)

    assert projection.converged?
    assert_operator projection.months_saved, :>, 0
    assert_operator projection.interest_saved.amount, :>, 0
    assert_operator projection.payoff_date, :<, loan.amortization_schedule.payoff_date
  end

  # The case that was unreachable in #103, and the reason convergence came back
  # with this change. A borrower far enough behind is not paying the loan off on
  # the contracted repayment -- and must not be shown a payoff date implying
  # otherwise.
  test "a loan too far behind to clear reports a balloon and no payoff date" do
    loan = build_loan(term_months: 24)
    loan.account.update!(balance: 400_000)

    projection = loan.payoff_projection(as_of: @today)

    assert projection.applicable?
    assert_not projection.converged?
    assert_nil projection.payoff_date
    assert_operator projection.balloon_amount.amount, :>, 0
    assert_equal 0, projection.months_saved, "no months are saved by a loan that never finishes"
  end

  test "is not applicable to a loan with no schedule or nothing left to owe" do
    unamortizable = build_loan(term_months: 24, rate_type: "teaser")
    assert_not unamortizable.payoff_projection(as_of: @today).applicable?

    cleared = build_loan(term_months: 24)
    cleared.account.update!(balance: 0)
    assert_not cleared.payoff_projection(as_of: @today).applicable?

    matured = build_loan(term_months: 24)
    assert_not matured.payoff_projection(as_of: Date.new(2040, 1, 1)).applicable?
  end


  # A variable loan's CONTRACT resizes the repayment at each rate change.
  # Holding one figure to maturity projects a repayment the lender will never
  # ask for, and the further out the change, the more wrong the payoff date.
  test "a variable projection re-amortises at a recorded rate change" do
    loan = build_loan(term_months: 24, rate_type: "variable")
    loan.update!(variable_rate_schedule: { (@today >> 3).iso8601 => "18.0" })
    loan.account.update!(balance: scheduled_balance_at(loan, @today))
    projection = loan.reload.payoff_projection(as_of: @today)

    before = projection.payments.first[:payment_amount]
    after = projection.payments.find { |p| p[:payment_date] >= (@today >> 3) }[:payment_amount]

    assert_operator after, :>, before,
      "the repayment must resize when the recorded rate rises"
  end

  private
    def build_loan(term_months:, rate_type: "fixed", interest_rate: 6)
      Account.create!(
        family: @family, name: "Loan #{SecureRandom.hex(4)}",
        balance: 500_000, currency: "USD",
        accountable: Loan.new(subtype: "mortgage", interest_rate: interest_rate,
                              term_months: term_months, rate_type: rate_type,
                              start_date: Date.new(2026, 1, 1))
      ).loan
    end

    def scheduled_balance_at(loan, date)
      loan.amortization_schedule.payments
        .select { |p| p.date <= date }.last.ending_balance.amount
    end
end
