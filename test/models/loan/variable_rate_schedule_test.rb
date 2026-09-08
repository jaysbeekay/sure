require "test_helper"

# The behaviour #104 exists for: a schedule that re-amortises at each recorded
# rate change, and does so on the right dates.
class Loan::VariableRateScheduleTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
  end

  test "a fixed loan is unaffected by this feature" do
    fixed = build_loan(rate_type: "fixed")

    # 500,000 at 6% over 360 months.
    assert_equal BigDecimal("2997.75"), fixed.amortization_schedule.periodic_payment.amount
    assert_equal 360, fixed.amortization_schedule.payments.count
    assert_not fixed.amortization_schedule.re_amortising?
  end

  test "a variable loan with no recorded changes runs at its base rate" do
    variable = build_loan(rate_type: "variable")
    fixed = build_loan(rate_type: "fixed")

    assert_not variable.amortization_schedule.re_amortising?
    assert_equal fixed.amortization_schedule.total_interest,
      variable.amortization_schedule.total_interest,
      "a variable loan with no changes recorded is running at its base rate, and must cost the same"
  end

  test "a recorded rate change resizes the repayment from its effective date" do
    loan = build_loan(
      rate_type: "variable", term_months: 24, start_date: Date.new(2026, 1, 1),
      variable_rate_schedule: { "2026-07-01" => "18.0" }
    )
    payments = loan.amortization_schedule.payments

    before = payments.find { |p| p.date == Date.new(2026, 6, 1) }
    on_change = payments.find { |p| p.date == Date.new(2026, 7, 1) }

    assert loan.amortization_schedule.re_amortising?
    assert_operator on_change.payment.amount, :>, before.payment.amount
  end

  # C10. Accrual windows are half-open: a rate effective 1 July belongs to
  # [Jul 1, Aug 1), not to the June that ran entirely at the old rate. Reading
  # one rate for both accrual and payment sizing bills the month ENDING on the
  # boundary at a rate that applied for none of it.
  test "a rate change landing on a payment date does not re-rate the month before it" do
    loan = build_loan(
      rate_type: "variable", term_months: 24, start_date: Date.new(2026, 1, 1),
      variable_rate_schedule: { "2026-07-01" => "18.0" }
    )
    payments = loan.amortization_schedule.payments
    closing_on_change = payments.find { |p| p.date == Date.new(2026, 7, 1) }

    # 6% on the balance the June->July window opened with, not 18%.
    expected = (closing_on_change.ending_balance.amount + closing_on_change.principal.amount) *
      BigDecimal("6") / 100 / 12

    assert_in_delta expected.to_f, closing_on_change.interest.amount.to_f, 0.01,
      "the month ending on the rate change must still be billed at the old rate"
  end

  # Regression for we-promise/sure#3296's second blocking finding. A segment
  # spanning a single 30-day month is `floor(30 / 30.44) == 0` payments under
  # average-month arithmetic, and was silently skipped. This engine counts real
  # payment dates, so the segment cannot vanish -- pinned end-to-end on the
  # money, because a skipped segment leaves a well-formed schedule and raises
  # nothing.
  test "a rate spike confined to a single 30-day month is charged, not skipped" do
    spiked = build_loan(
      rate_type: "variable", term_months: 24, start_date: Date.new(2026, 1, 1),
      variable_rate_schedule: { "2026-04-01" => "18.0", "2026-05-01" => "6.0" }
    )
    flat = build_loan(rate_type: "variable", term_months: 24, start_date: Date.new(2026, 1, 1))

    assert_equal 30, (Date.new(2026, 5, 1) - Date.new(2026, 4, 1)).to_i,
      "premise: the segment under test spans a 30-day month"

    assert_operator spiked.amortization_schedule.total_interest.amount,
      :>, flat.amortization_schedule.total_interest.amount,
      "a rate spike confined to one 30-day month must change the interest charged"
  end

  test "current_variable_rate reads the change in force, and the base rate before any" do
    loan = build_loan(
      rate_type: "variable",
      variable_rate_schedule: { "2026-04-01" => "18.0", "2026-07-01" => "9.5" }
    )

    assert_equal BigDecimal("6"), loan.current_variable_rate(Date.new(2026, 3, 31))
    assert_equal BigDecimal("18.0"), loan.current_variable_rate(Date.new(2026, 4, 1))
    assert_equal BigDecimal("18.0"), loan.current_variable_rate(Date.new(2026, 6, 30))
    assert_equal BigDecimal("9.5"), loan.current_variable_rate(Date.new(2026, 7, 1))
  end

  test "a fixed loan ignores any rate changes recorded against it" do
    loan = build_loan(rate_type: "fixed", variable_rate_schedule: { "2026-04-01" => "18.0" })

    assert_equal BigDecimal("6"), loan.current_variable_rate(Date.new(2026, 12, 1))
    assert_not loan.amortization_schedule.re_amortising?
  end

  test "re-entering an effective date replaces that row rather than adding a second" do
    loan = build_loan(rate_type: "variable")

    loan.rate_changes = [
      { effective_date: "2026-04-01", rate: "7.5" },
      { effective_date: "2026-04-01", rate: "8.25" }
    ]

    assert_equal({ "2026-04-01" => "8.25" }, loan.variable_rate_schedule)
  end

  test "blank and unparseable rows are dropped rather than raising" do
    loan = build_loan(rate_type: "variable")

    loan.rate_changes = [
      { effective_date: "", rate: "7.5" },
      { effective_date: "2026-04-01", rate: "" },
      { effective_date: "not a date", rate: "7.5" },
      { effective_date: "2026-05-01", rate: "7.5" }
    ]

    assert_equal({ "2026-05-01" => "7.5" }, loan.variable_rate_schedule)
  end

  test "origination prefers a recorded start date over the account's first valuation" do
    loan = build_loan(rate_type: "fixed")
    assert_equal loan.account.first_valuation&.date || loan.account.opening_anchor_date,
      loan.origination_date

    loan.update!(start_date: Date.new(2020, 3, 15))
    assert_equal Date.new(2020, 3, 15), loan.origination_date
  end

  private
    def build_loan(rate_type:, interest_rate: 6, term_months: 360, start_date: nil,
                   variable_rate_schedule: {})
      Account.create!(
        family: @family,
        name: "Loan #{SecureRandom.hex(4)}",
        balance: 500_000,
        currency: "USD",
        accountable: Loan.new(
          subtype: "mortgage",
          interest_rate: interest_rate,
          term_months: term_months,
          rate_type: rate_type,
          start_date: start_date,
          variable_rate_schedule: variable_rate_schedule
        )
      ).loan
    end
end
