require "test_helper"

class Demo::GeneratorTest < ActiveSupport::TestCase
  setup do
    @family = Family.create!(name: "Demo Family")
    @admin_user = create_user!(@family, "demo-admin@example.com")
  end

  test "production sample reset includes Wallet in the normal accounts and transactions phases" do
    Rails.stubs(:env).returns(ActiveSupport::EnvironmentInquirer.new("production"))
    generator = Demo::Generator.new(seed: 42)
    stub_non_wallet_activity(generator)
    @family.expects(:sync_later)

    generator.generate_new_user_data_for!(@family, email: @admin_user.email)

    assert_wallet_demo_activity
  end

  test "production default demo includes Wallet in the normal accounts and transactions phases" do
    Rails.stubs(:env).returns(ActiveSupport::EnvironmentInquirer.new("production"))
    generator = Demo::Generator.new(seed: 42)
    generator.stubs(:create_family_and_users!).returns(@family)
    generator.stubs(:create_monitoring_api_key!)
    stub_non_wallet_activity(generator)

    generator.generate_default_data!(skip_clear: true)

    assert_wallet_demo_activity
  end

  test "sample data generates loan payments before its transaction commits" do
    generator = Demo::Generator.new(seed: 42)
    stub_non_loan_activity(generator)
    @family.expects(:sync_later)

    generator.generate_new_user_data_for!(@family, email: @admin_user.email)

    assert_demo_loan_payments
  end

  test "default demo generates loan payments inside a refresh transaction" do
    generator = Demo::Generator.new(seed: 42)
    generator.stubs(:create_family_and_users!).returns(@family)
    generator.stubs(:create_monitoring_api_key!)
    stub_non_loan_activity(generator)

    ActiveRecord::Base.transaction do
      generator.generate_default_data!(skip_clear: true, email: @admin_user.email)
      assert_demo_loan_payments
    end
  end

  test "monitoring api key creation reassigns stale demo monitoring key owned by another user" do
    stale_family = Family.create!(name: "Old Demo Family")
    stale_user = create_user!(stale_family, "old-demo-admin@example.com")
    stale_key = stale_user.api_keys.create!(
      name: "monitoring",
      key: ApiKey::DEMO_MONITORING_KEY,
      scopes: [ "read" ],
      source: "monitoring"
    )

    monitoring_key = Demo::Generator.new.send(:create_monitoring_api_key!, @family)

    assert_equal stale_key.id, monitoring_key.id
    assert_equal @admin_user, monitoring_key.user
    assert_equal "monitoring", monitoring_key.source
    assert_equal [ "read" ], monitoring_key.scopes
    assert_equal 1, ApiKey.where(display_key: ApiKey::DEMO_MONITORING_KEY).count
  end

  test "monitoring api key creation reuses the current admin user's key" do
    existing_key = @admin_user.api_keys.create!(
      name: "monitoring",
      key: ApiKey::DEMO_MONITORING_KEY,
      scopes: [ "read" ],
      source: "monitoring"
    )

    monitoring_key = Demo::Generator.new.send(:create_monitoring_api_key!, @family)

    assert_equal existing_key, monitoring_key
    assert_equal 1, ApiKey.where(display_key: ApiKey::DEMO_MONITORING_KEY).count
  end

  # Regression for a `rake demo_data:default` crash: the goal-seeding matrix
  # linked several active goals to the same account as a 100%-whole-account
  # claim each, which violates GoalAccount#whole_account_link_must_be_exclusive
  # the moment the second one tries to save.
  test "generate_goals! seeds the full matrix without raising" do
    @family.update!(currency: "USD")
    @family.accounts.create!(accountable: Depository.new, name: "Primary Checking",
                              currency: @family.currency, balance: 150_000)
    @family.accounts.create!(accountable: Depository.new, name: "Secondary Savings",
                              currency: @family.currency, balance: 10_000)

    assert_difference "@family.goals.count", 9 do
      Demo::Generator.new.send(:generate_goals!, @family)
    end
  end

  # The demo family's loans were bare Loan.new records -- no rate, no term, and
  # the mortgage's principal a transaction rather than an opening valuation --
  # so none of them had a schedule to show. The mortgage is adjustable with
  # recorded changes, so the demo shows a schedule re-amortising; the other two
  # are fixed.
  test "demo loans carry the terms and principal a schedule is built from" do
    @family.update!(currency: "USD")
    generator = Demo::Generator.new(seed: 42)
    generator.send(:create_realistic_categories!, @family)
    generator.send(:create_realistic_accounts!, @family)
    generator.send(:generate_major_purchases!)

    mortgage = @family.accounts.find_by!(name: "Home Mortgage").loan
    assert mortgage.variable_rate_type?, "the demo mortgage should be adjustable"
    assert_equal BigDecimal("320000"), mortgage.original_balance.amount
    assert_equal mortgage.start_date, mortgage.origination_date
    assert mortgage.amortization_schedule.re_amortising?,
      "a recorded rate change must move the demo mortgage's repayment"

    # The leverage card reads the loan's down payment; the cash-flow history
    # records the deposit as a transaction. The two must be the same figure.
    checking = generator.instance_variable_get(:@chase_checking)
    deposit = checking.entries.find_by!(name: "Home Down Payment")
    assert_equal deposit.amount, mortgage.down_payment,
      "the mortgage's down payment must match the deposit the demo records"

    [ "Car Loan", "Student Loan" ].each do |name|
      loan = @family.accounts.find_by!(name: name).loan
      assert_not loan.variable_rate_type?, "#{name} should be fixed"
      assert loan.amortization_schedule&.payments&.any?, "#{name} should have a schedule"
    end
  end

  # Owner review of #3474: the demo loans' figures must add up. Each loan pays
  # its own schedule's principal and interest and nothing else moves its
  # balance, so today it owes what its schedule says -- except the student
  # loan, which made one extra payment (2,000, a year ago) and so is ahead of
  # its schedule for a real reason.
  test "demo loans owe what their own schedules say, the student loan ahead by its extra payment" do
    @family.update!(currency: "USD")
    generator = Demo::Generator.new(seed: 42)
    generator.send(:create_realistic_categories!, @family)
    generator.send(:create_realistic_accounts!, @family)
    generator.send(:generate_housing_transactions!)
    generator.send(:generate_transportation_transactions!)
    generator.send(:generate_major_purchases!)
    generator.send(:generate_loan_payments!)
    checking = generator.instance_variable_get(:@chase_checking)
    today = Date.current

    { "Home Mortgage" => 0, "Car Loan" => 0, "Student Loan" => 2_000 }.each do |name, extra|
      account = @family.accounts.find_by!(name: name)
      Sync.create!(syncable: account).perform
      due = account.reload.loan.amortization_schedule.payments.select { |payment| payment.date <= today }
      assert due.any?, "#{name} must have payments due, or this asserts nothing"
      assert_in_delta due.last.ending_balance.amount - extra, account.balance, 0.01,
        "#{name} must owe its schedule's balance today#{" less its extra payment" if extra.positive?}"
    end

    student = @family.accounts.find_by!(name: "Student Loan").loan
    due = student.amortization_schedule.payments.select { |payment| payment.date <= today }
    booked_interest = checking.entries.where(name: "Student Loan Payment Interest").sum(:amount)
    assert_in_delta due.sum { |payment| payment.interest.amount }, booked_interest, 0.01,
      "the interest booked must be the schedule's interest, not a flat figure"
  end

  # What the chart says about the demo loans follows
  # from their balances. The mortgage and the car loan sit on their schedules,
  # so each pays off on time; the student loan is ahead by its extra payment,
  # so it pays off early. None of them is quoted early while it is not ahead.
  test "demo loans project payoffs that match their balances" do
    @family.update!(currency: "USD")
    generator = Demo::Generator.new(seed: 42)
    generator.send(:create_realistic_categories!, @family)
    generator.send(:create_realistic_accounts!, @family)
    generator.send(:generate_housing_transactions!)
    generator.send(:generate_transportation_transactions!)
    generator.send(:generate_major_purchases!)
    generator.send(:generate_loan_payments!)
    today = Date.current

    projections = [ "Home Mortgage", "Car Loan", "Student Loan" ].to_h do |name|
      account = @family.accounts.find_by!(name: name)
      Sync.create!(syncable: account).perform
      [ name, account.reload.loan.payoff_projection(as_of: today) ]
    end

    [ "Home Mortgage", "Car Loan" ].each do |name|
      assert projections[name].converged?, "#{name} is on schedule, so its projection must clear the balance"
      assert_equal 0, projections[name].months_saved, "#{name} is on schedule, so it must pay off on time"
    end
    assert projections["Student Loan"].converged?, "the student loan's projection must clear the balance"
    assert_operator projections["Student Loan"].months_saved, :>, 0,
      "the extra payment must bring the student loan's payoff forward"
  end

  # Fork (#408): the terms the issue specifies, field by field. The tests above
  # measure each loan against its own schedule, so a term changed or dropped
  # (one of the mortgage's two rate changes, say) still agrees with itself.
  test "demo loans carry the terms the issue specifies" do
    @family.update!(currency: "USD")
    generator = Demo::Generator.new(seed: 42)
    generator.send(:create_realistic_categories!, @family)
    generator.send(:create_realistic_accounts!, @family)
    mortgage_start = 5.years.ago.to_date
    loans_start = 37.months.ago.beginning_of_month.to_date

    expected = {
      "Home Mortgage" => [ "mortgage", "adjustable", BigDecimal("6.25"), 360, mortgage_start, BigDecimal("320000"), BigDecimal("70000"), BigDecimal("0.36"), "level_term" ],
      "Car Loan" => [ "auto", "fixed", BigDecimal("6.9"), 60, loans_start, BigDecimal("24000"), BigDecimal("4000"), BigDecimal("0.5"), "decreasing_life" ],
      "Student Loan" => [ "student", "fixed", BigDecimal("5.5"), 120, loans_start, BigDecimal("42000"), nil, nil, nil ]
    }
    expected.each do |name, terms|
      loan = @family.accounts.find_by!(name: name).loan
      assert_equal terms, [ loan.subtype, loan.rate_type, loan.interest_rate, loan.term_months, loan.start_date,
                            loan.initial_balance, loan.down_payment, loan.insurance_rate, loan.insurance_rate_type ], name
    end

    mortgage = @family.accounts.find_by!(name: "Home Mortgage").loan
    assert_equal [ [ mortgage_start >> 24, BigDecimal("5.5") ], [ mortgage_start >> 48, BigDecimal("6.75") ] ],
      mortgage.variable_rates
    assert_empty @family.accounts.find_by!(name: "Car Loan").loan.variable_rates
    assert_empty @family.accounts.find_by!(name: "Student Loan").loan.variable_rates
  end

  # Fork (#408): the housing step used to pay the mortgage too -- 2,800 from
  # checking and an 800 principal entry on the mortgage on the first of every
  # month -- on top of generate_loan_payments!, and the major-purchases step
  # booked the 320,000 as a transaction. Measured as what each step adds,
  # because the loan step books entries named "Mortgage Payment" as well.
  test "the mortgage is paid once per scheduled date, by its schedule alone" do
    @family.update!(currency: "USD")
    generator = Demo::Generator.new(seed: 42)
    generator.send(:create_realistic_categories!, @family)
    generator.send(:create_realistic_accounts!, @family)
    mortgage = @family.accounts.find_by!(name: "Home Mortgage")
    checking = generator.instance_variable_get(:@chase_checking)

    checking_entries_before = checking.entries.count
    assert_no_difference [ -> { mortgage.entries.count }, -> { checking.entries.where(name: "Mortgage Payment").count } ] do
      generator.send(:generate_housing_transactions!)
    end
    assert_operator checking.entries.count, :>, checking_entries_before,
      "the housing step must still book its utilities, or the no-difference above asserts nothing"

    assert_no_difference -> { mortgage.entries.transactions.count } do
      generator.send(:generate_major_purchases!)
    end
    opening = mortgage.entries.valuations.sole
    assert_equal [ "opening_anchor", BigDecimal("320000"), mortgage.loan.start_date ],
      [ opening.entryable.kind, opening.amount, opening.date ]

    generator.send(:generate_loan_payments!)
    due_dates = mortgage.loan.reload.amortization_schedule.payments.map(&:date).select { |date| date <= Date.current }
    assert due_dates.any?, "the mortgage must have payments due, or this asserts nothing"
    assert_equal due_dates.index_with(1), mortgage.entries.transactions.group(:date).count,
      "the mortgage must receive exactly one payment on each scheduled date, and nothing else"
    assert_equal due_dates.index_with(1), checking.entries.where(name: "Mortgage Payment").group(:date).count,
      "checking must pay the mortgage once per scheduled date"
  end

  # Fork (#408): the flat payment on the previous car stops before the demo car
  # loan starts, so the car is not paid twice over the loan's months.
  test "the previous car's flat payments stop before the demo car loan starts" do
    @family.update!(currency: "USD")
    generator = Demo::Generator.new(seed: 42)
    generator.send(:create_realistic_categories!, @family)
    generator.send(:create_realistic_accounts!, @family)
    checking = generator.instance_variable_get(:@chase_checking)
    car_loan_start = @family.accounts.find_by!(name: "Car Loan").loan.start_date
    flat_payments = checking.entries.where(name: "Auto Loan Payment")
    assert_not flat_payments.exists?, "no car payment may exist before the step runs"

    generator.send(:generate_transportation_transactions!)

    assert flat_payments.where("date < ?", car_loan_start).exists?,
      "the previous car's payments must still be booked, or the check below asserts nothing"
    assert_not flat_payments.where("date >= ?", car_loan_start).exists?,
      "no flat car payment may fall on or after the demo car loan's start"
  end

  # Fork (#408): the loan page's payoff card renders only for an applicable
  # projection. Bare Loan.new demo loans had none.
  test "every demo loan has an applicable payoff projection" do
    @family.update!(currency: "USD")
    generator = Demo::Generator.new(seed: 42)
    generator.send(:create_realistic_categories!, @family)
    generator.send(:create_realistic_accounts!, @family)
    generator.send(:generate_major_purchases!)
    generator.send(:generate_loan_payments!)

    [ "Home Mortgage", "Car Loan", "Student Loan" ].each do |name|
      account = @family.accounts.find_by!(name: name)
      Sync.create!(syncable: account).perform
      assert account.reload.loan.payoff_projection(as_of: Date.current).applicable?,
        "#{name} must have a payoff projection to show"
    end
  end

  private
    # Keep the actual loan terms, opening valuations and payment generation in
    # the public orchestration. Unrelated history and provider syncs are omitted
    # so this regression tests the transaction boundary without external calls.
    def stub_non_loan_activity(generator)
      %i[load_securities! generate_salary_history! generate_housing_transactions!
         generate_food_transactions! generate_transportation_transactions!
         generate_entertainment_transactions! generate_shopping_transactions!
         generate_healthcare_transactions! generate_travel_transactions!
         generate_personal_care_transactions! generate_investment_transactions!
         generate_transfers_and_payments! generate_regular_expenses!
         generate_legacy_transactions! generate_crypto_and_misc_assets!
         generate_budget_auto_fill! generate_goals! sync_family_accounts!].each do |step|
        generator.stubs(step)
      end
      Demo::FinancekitGenerator.any_instance.stubs(:create_accounts!)
      Demo::FinancekitGenerator.any_instance.stubs(:create_transactions!)
    end

    def assert_demo_loan_payments
      {
        "Home Mortgage" => "Mortgage Payment",
        "Student Loan" => "Student Loan Payment",
        "Car Loan" => "Auto Loan Payment"
      }.each do |name, memo|
        account = @family.accounts.find_by!(name: name)
        due = account.loan.amortization_schedule.payments.select { |payment| payment.date <= Date.current }
        assert due.any?, "#{name} should have payments due"
        payments = account.entries.transactions.where(name: memo)
        assert_equal due.size, payments.count, "#{name} should record every scheduled payment"
        assert_equal(-due.sum { |payment| payment.principal.amount }, payments.sum(:amount))
      end
    end

    # Exercise the actual account/transaction orchestration without generating
    # years of unrelated spending, securities, budgets and goals in each test.
    def stub_non_wallet_activity(generator)
      %i[load_securities! generate_salary_history! generate_housing_transactions!
         generate_food_transactions! generate_transportation_transactions!
         generate_entertainment_transactions! generate_shopping_transactions!
         generate_healthcare_transactions! generate_travel_transactions!
         generate_personal_care_transactions! generate_investment_transactions!
         generate_major_purchases! generate_transfers_and_payments! generate_loan_payments!
         generate_regular_expenses! generate_legacy_transactions! generate_crypto_and_misc_assets!
         generate_budget_auto_fill! generate_goals! sync_family_accounts!].each do |step|
        generator.stubs(step)
      end
    end

    def assert_wallet_demo_activity
      item = @family.financekit_items.find_by!(enrollment_id: Demo::FinancekitGenerator::ENROLLMENT_ID)
      assert_equal [ "Apple Card", "Apple Cash", "Nancy's Apple Cash" ], item.accounts.order(:name).pluck(:name)
      assert item.accounts.all?(&:linked?)
      assert item.accounts.all? { |account| account.entries.exists? }
      assert item.last_imported_at
      card = item.accounts.find_by!(name: "Apple Card")
      checking = @family.accounts.find_by!(name: "Chase Premier Checking")
      assert_equal checking, card.entries.find_by!(name: "Apple Card Payment").entryable.transfer.from_account
      assert item.accounts.find_by!(name: "Apple Cash").entries.exists?(name: "Apple Card Daily Cash")
      assert item.accounts.find_by!(name: "Nancy's Apple Cash").entries.exists?(name: "Movie Theater")
      assert_not @family.accounts.exists?(name: "Wallet Demo Checking")
    end

    def create_user!(family, email)
      family.users.create!(
        first_name: "Demo",
        last_name: "Admin",
        email: email,
        password: "password123",
        role: :admin,
        onboarded_at: Time.current,
        ai_enabled: true,
        show_sidebar: true,
        show_ai_sidebar: true,
        ui_layout: :dashboard
      )
    end
end
