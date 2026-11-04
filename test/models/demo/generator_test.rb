require "test_helper"

class Demo::GeneratorTest < ActiveSupport::TestCase
  setup do
    @family = Family.create!(name: "Demo Family")
    @admin_user = create_user!(@family, "demo-admin@example.com")
  end

  %i[generate_default_data! generate_empty_data! generate_new_user_data!].each do |mode|
    test "#{mode} enables AI and preview features for both demo users without a provider" do
      User.find_by!(email: "user@example.com").update!(email: "existing-user@example.com")
      User.any_instance.stubs(:ai_available?).returns(false)
      generator = Demo::Generator.new(seed: 42)
      %i[create_realistic_categories! create_realistic_accounts! create_realistic_transactions!
         generate_budget_auto_fill! generate_goals! create_monitoring_api_key!].each do |step|
        generator.stubs(step)
      end

      generator.public_send(mode, skip_clear: true)

      family = User.find_by!(email: "user@example.com").family
      assert_equal %w[admin member], family.users.order(:role).pluck(:role)
      family.users.each do |user|
        assert user.ai_enabled, "#{user.role} should have AI enabled"
        assert user.show_ai_sidebar?, "#{user.role} should start with the AI sidebar open"
        assert user.preview_features_enabled?, "#{user.role} should have preview access"
      end
    end
  end

  test "default demo data links the public on-chain wallets without reading a chain" do
    # WebMock refuses any request, so this also proves generation stays offline.
    User.find_by!(email: "user@example.com").update!(email: "existing-user@example.com")
    generator = Demo::Generator.new(seed: 42)
    %i[create_realistic_categories! create_realistic_accounts! create_realistic_transactions!
       generate_budget_auto_fill! generate_goals! create_monitoring_api_key!].each do |step|
      generator.stubs(step)
    end

    generator.generate_default_data!(skip_clear: true)

    item = User.find_by!(email: "user@example.com").family.onchain_wallet_item
    expected = Demo::Generator::ONCHAIN_DEMO_WALLETS.map { |wallet| [ wallet[:chain], Onchain::Chains.canonical_address(wallet[:chain], wallet[:address]) ] }
    assert_equal expected.sort, item.wallet_keys.sort
    assert_equal %w[BTC ETH SOL USDC USDC USDT USDT], item.onchain_wallet_accounts.pluck(:symbol).sort
    assert item.onchain_wallet_accounts.all? { |row| row.account&.accountable_type == "Crypto" }
    assert_equal 1, item.syncs.count, "the item sync fills in the real balances"
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
    skip "Fork keeps its own demo loans (#184; generator.rb taken fork-side in #232/#272): they carry no terms and pay flat figures, so there is no schedule to match. Kept, not dropped, pending the owner's call on porting upstream's schedule-driven demo loans."
    generator = Demo::Generator.new(seed: 42)
    stub_non_loan_activity(generator)
    @family.expects(:sync_later)

    generator.generate_new_user_data_for!(@family, email: @admin_user.email)

    assert_demo_loan_payments
  end

  test "default demo generates loan payments inside a refresh transaction" do
    skip "Fork keeps its own demo loans (#184; generator.rb taken fork-side in #232/#272): they carry no terms and pay flat figures, so there is no schedule to match. Kept, not dropped, pending the owner's call on porting upstream's schedule-driven demo loans."
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
