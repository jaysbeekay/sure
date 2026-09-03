require "test_helper"

class LoanAmortizationSchedulesControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @user = users(:family_admin)
    @account = accounts(:loan)
  end

  # Regression: the loan overview tab renders Loans::AmortizationSchedule,
  # whose generate/regenerate/view-all controls called route helpers that
  # don't exist for this account-nested, index/create-only resource
  # (loan_amortization_schedule_path, loan_amortization_schedules_path) --
  # Rails raises NoMethodError for an undefined route helper, so this
  # would fail on the very first render, not just on a button click.
  test "account page renders the amortization schedule controls without error" do
    get account_url(@account)

    assert_response :success
  end

  test "create generates a schedule and redirects to the account" do
    assert_difference -> { @account.loan.amortization_schedules.count }, @account.loan.term_months do
      post account_loan_amortization_schedules_path(@account)
    end

    assert_redirected_to @account
    assert_equal I18n.t("loan_amortization_schedules.create.schedule_generated"), flash[:notice]
  end

  test "create accepts an explicit start_date" do
    post account_loan_amortization_schedules_path(@account), params: { start_date: "2025-01-01" }

    assert_redirected_to @account
    first_entry = @account.loan.amortization_schedules.order(:payment_number).first
    assert_equal Date.new(2025, 1, 1), first_entry.payment_date
  end

  # Regression: Date.parse raised unrescued on a malformed start_date,
  # returning a 500 to an otherwise-authorized user instead of a normal
  # redirect-with-alert.
  test "create redirects with an alert instead of erroring on an invalid start_date" do
    assert_no_difference -> { @account.loan.amortization_schedules.count } do
      post account_loan_amortization_schedules_path(@account), params: { start_date: "not-a-date" }
    end

    assert_redirected_to @account
    assert_equal I18n.t("loan_amortization_schedules.create.invalid_start_date"), flash[:alert]
  end

  test "create redirects with an alert when the loan is missing term or rate details" do
    incomplete_loan_account = Account.create! \
      family: @user.family,
      name: "Incomplete Loan",
      balance: 100000,
      currency: "USD",
      accountable: Loan.create!(subtype: "mortgage", rate_type: "fixed")

    assert_no_difference -> { incomplete_loan_account.loan.amortization_schedules.count } do
      post account_loan_amortization_schedules_path(incomplete_loan_account)
    end

    assert_redirected_to incomplete_loan_account
    assert_equal I18n.t("loan_amortization_schedules.create.missing_loan_details"), flash[:alert]
  end

  test "index lists the generated schedule" do
    @account.loan.generate_amortization_schedule(start_date: Date.new(2025, 1, 1))

    get account_loan_amortization_schedules_path(@account)

    assert_response :success
    assert_select "tbody tr", count: @account.loan.term_months
  end
end
