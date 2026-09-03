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

    assert_equal 2245, loan_account.loan.monthly_payment.amount
  end

  test "generates amortization schedule for fixed rate loan" do
    loan = Loan.create!(
      subtype: "mortgage",
      interest_rate: 3.5,
      term_months: 12,
      rate_type: "fixed"
    )
    loan_account = Account.create! \
      family: families(:dylan_family),
      name: "Test Mortgage",
      balance: 100000,
      currency: "USD",
      accountable: loan

    loan.generate_amortization_schedule(start_date: Date.new(2025, 1, 1))

    assert_equal 12, loan.amortization_schedules.count

    first_schedule = loan.amortization_schedules.find_by(payment_number: 1)
    assert_not_nil first_schedule
    assert_equal 100000, first_schedule.beginning_balance
    assert_equal Date.new(2025, 1, 1), first_schedule.payment_date
    assert first_schedule.interest_payment > 0
    assert first_schedule.principal_payment > 0
    assert first_schedule.payment_amount > 0
    assert_equal 3.5, first_schedule.interest_rate

    last_schedule = loan.amortization_schedules.find_by(payment_number: 12)
    assert last_schedule.ending_balance < 50
  end

  test "supports variable interest rate loans" do
    loan = Loan.create!(
      subtype: "mortgage",
      interest_rate: 3.5,
      term_months: 12,
      rate_type: "variable"
    )
    loan_account = Account.create! \
      family: families(:dylan_family),
      name: "Variable Mortgage",
      balance: 100000,
      currency: "USD",
      accountable: loan

    assert_equal "variable", loan.rate_type
    assert loan.rate_change_schedule.is_a?(Hash)
  end

  test "adds and tracks rate changes" do
    loan = Loan.create!(
      subtype: "mortgage",
      interest_rate: 3.5,
      term_months: 12,
      rate_type: "variable"
    )
    loan_account = Account.create! \
      family: families(:dylan_family),
      name: "Variable Mortgage",
      balance: 100000,
      currency: "USD",
      accountable: loan

    new_date = Date.new(2025, 6, 1)
    new_rate = 4.5

    loan.add_rate_change(new_date, new_rate)

    assert_equal new_rate, loan.rate_change_schedule[new_date.to_s]
    assert_equal new_date, loan.next_rate_change_date
  end

  test "retrieves rate for specific date" do
    loan = Loan.create!(
      subtype: "mortgage",
      interest_rate: 3.5,
      term_months: 24,
      rate_type: "variable"
    )
    loan_account = Account.create! \
      family: families(:dylan_family),
      name: "Variable Mortgage",
      balance: 100000,
      currency: "USD",
      accountable: loan

    loan.add_rate_change(Date.new(2025, 6, 1), 4.0)
    loan.add_rate_change(Date.new(2025, 12, 1), 4.5)

    assert_equal 3.5, loan.rate_for_date(Date.new(2025, 1, 1))
    assert_equal 4.0, loan.rate_for_date(Date.new(2025, 6, 15))
    assert_equal 4.5, loan.rate_for_date(Date.new(2025, 12, 1))
    assert_equal 4.5, loan.rate_for_date(Date.new(2026, 1, 1))
  end

  test "generates amortization schedule with rate changes" do
    loan = Loan.create!(
      subtype: "mortgage",
      interest_rate: 3.5,
      term_months: 12,
      rate_type: "variable"
    )
    loan_account = Account.create! \
      family: families(:dylan_family),
      name: "Variable Mortgage",
      balance: 100000,
      currency: "USD",
      accountable: loan

    loan.add_rate_change(Date.new(2025, 7, 1), 4.5)

    loan.generate_amortization_schedule(start_date: Date.new(2025, 1, 1))

    assert_equal 12, loan.amortization_schedules.count

    first_half_schedules = loan.amortization_schedules.where("payment_number <= 6")
    second_half_schedules = loan.amortization_schedules.where("payment_number > 6")

    first_half_schedules.each do |schedule|
      assert_equal 3.5, schedule.interest_rate
    end

    second_half_schedules.each do |schedule|
      assert_equal 4.5, schedule.interest_rate
    end
  end

  # Regression: current_payment_amount used to return the *last* scheduled
  # payment regardless of today's date, so a variable-rate loan with a
  # future rate change would immediately show that future payment amount.
  test "monthly_payment reflects the currently effective payment for a variable rate loan, not the final one" do
    travel_to Date.new(2025, 4, 15) do
      loan = Loan.create!(
        subtype: "mortgage",
        interest_rate: 3.5,
        term_months: 12,
        rate_type: "variable"
      )
      loan_account = Account.create! \
        family: families(:dylan_family),
        name: "Variable Mortgage",
        balance: 100000,
        currency: "USD",
        accountable: loan

      loan.add_rate_change(Date.new(2025, 7, 1), 4.5)
      loan.generate_amortization_schedule(start_date: Date.new(2025, 1, 1))

      # "Today" (Apr 15, 2025) falls within the April period (payment_number
      # 4), which precedes the July rate change -- the effective payment
      # should be that period's, not the schedule's final (December) one.
      april_schedule = loan.amortization_schedules.find_by(payment_number: 4)
      final_schedule = loan.amortization_schedules.order(:payment_number).last
      assert_not_equal final_schedule.payment_amount.round, april_schedule.payment_amount.round,
        "test setup should exercise a real payment-amount divergence between the current and final periods"

      assert_equal april_schedule.payment_amount.round, loan.monthly_payment.amount
    end
  end

  # Regression: rate_for_date used to return nil (instead of the loan's base
  # interest_rate) whenever no configured rate change had taken effect yet --
  # including when no rate changes exist at all, or for a date before the
  # earliest one.
  test "rate_for_date returns the base interest rate when no rate change is applicable yet" do
    loan = Loan.create!(
      subtype: "mortgage",
      interest_rate: 3.5,
      term_months: 12,
      rate_type: "variable"
    )
    loan_account = Account.create! \
      family: families(:dylan_family),
      name: "Variable Mortgage",
      balance: 100000,
      currency: "USD",
      accountable: loan

    assert_equal 3.5, loan.rate_for_date(Date.current), "no rate changes exist yet"

    loan.add_rate_change(Date.new(2030, 1, 1), 4.5)
    assert_equal 3.5, loan.rate_for_date(Date.current), "the only rate change is still in the future"
  end

  # Regression: generate_amortization_schedule deleted the existing schedule
  # before inserting replacement rows one at a time, outside a transaction --
  # a failure partway through left the loan with no (or a partial) schedule.
  test "generate_amortization_schedule leaves the prior schedule intact when generation fails" do
    loan = Loan.create!(
      subtype: "mortgage",
      interest_rate: 3.5,
      term_months: 12,
      rate_type: "fixed"
    )
    loan_account = Account.create! \
      family: families(:dylan_family),
      name: "Test Mortgage",
      balance: 100000,
      currency: "USD",
      accountable: loan

    loan.generate_amortization_schedule(start_date: Date.new(2025, 1, 1))
    original_count = loan.amortization_schedules.count
    original_first_date = loan.amortization_schedules.order(:payment_number).first.payment_date

    LoanAmortizationSchedule.any_instance.stubs(:save!).raises(ActiveRecord::RecordInvalid.new(LoanAmortizationSchedule.new))

    assert_raises(ActiveRecord::RecordInvalid) do
      loan.generate_amortization_schedule(start_date: Date.new(2025, 2, 1))
    end

    assert_equal original_count, loan.amortization_schedules.count
    assert_equal original_first_date, loan.amortization_schedules.order(:payment_number).first.payment_date
  end

  test "monthly payment returns nil when data is missing" do
    loan = Loan.create!(
      subtype: "mortgage",
      rate_type: "fixed"
    )
    loan_account = Account.create! \
      family: families(:dylan_family),
      name: "Test Loan",
      balance: 100000,
      currency: "USD",
      accountable: loan

    assert_nil loan.monthly_payment
  end

  test "zero interest loan calculates correctly" do
    loan = Loan.create!(
      subtype: "mortgage",
      interest_rate: 0,
      term_months: 12,
      rate_type: "fixed"
    )
    loan_account = Account.create! \
      family: families(:dylan_family),
      name: "Zero Interest Loan",
      balance: 12000,
      currency: "USD",
      accountable: loan

    payment = loan.monthly_payment
    assert_equal 1000, payment.amount
  end
end
