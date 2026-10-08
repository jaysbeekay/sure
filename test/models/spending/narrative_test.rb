require "test_helper"

class Spending::NarrativeTest < ActiveSupport::TestCase
  include EntriesTestHelper

  # Mid-month in a month no fixture touches.
  TODAY = Date.new(2024, 3, 14)

  setup do
    @family = families(:dylan_family)
    @user = users(:family_admin)
  end

  def narrative(on: TODAY, family: @family, user: @user, household: false)
    Spending::Narrative.new(family: family, user: user, on: on, household: household)
  end

  def create_budget(user: nil, budgeted: 1000, start_date: Date.new(2024, 3, 1))
    Budget.create!(family: @family, user: user, start_date: start_date, end_date: start_date.end_of_month,
                   budgeted_spending: budgeted, expected_income: 0, currency: "USD")
  end

  test "the period runs from the start of the month to the injected date" do
    period = narrative.period

    assert_equal Date.new(2024, 3, 1), period.start_date
    assert_equal TODAY, period.end_date
  end

  test "a family with a custom month start gets its own month" do
    @family.update!(month_start_day: 10)

    period = narrative.period

    assert_equal Date.new(2024, 3, 10), period.start_date
    assert_equal TODAY, period.end_date
  end

  test "the previous period is the equal-length window before it" do
    previous = narrative.previous_period

    assert_equal narrative.period.days, previous.days
    assert_equal narrative.period.start_date - 1.day, previous.end_date
  end

  test "the budget is the one covering the date, found without creating anything" do
    budget = create_budget

    assert_equal budget, narrative.budget
    assert_no_difference "Budget.count" do
      narrative(on: Date.new(2023, 1, 10)).budget
    end
    assert_nil narrative(on: Date.new(2023, 1, 10)).budget
  end

  test "pace is nil when there is no budget, and spend still reads" do
    result = narrative(on: Date.new(2023, 1, 10))

    assert_nil result.pace
    assert_equal 0, result.spent
    assert_equal [], result.top_movers
  end

  test "pace is computed against the injected date" do
    create_budget(budgeted: 1000)
    create_transaction(amount: 600, date: Date.new(2024, 3, 3), name: "Narrative spend")

    # 14 of 31 days elapsed: 600 of 1000 is well ahead of pace.
    assert_equal :approaching, narrative(on: Date.new(2024, 3, 14)).pace.status
    # 31 of 31: the same 600 is comfortably inside the budget.
    assert_equal :on_track, narrative(on: Date.new(2024, 3, 31)).pace.status
  end

  test "a personal-budgets family uses the viewer's own budget, not the household one" do
    @family.update!(personal_budgets: true)
    household = create_budget(budgeted: 1000)
    personal = create_budget(user: @user, budgeted: 2000)

    assert_equal personal, narrative.budget
    assert_not_equal household, narrative.budget
  end

  # Both directions: the family's own budget is found, and a different family's
  # budget for the same month is not -- absence alone would also pass for a
  # lookup that returned nil for everyone.
  test "another family's budget is never used, and the family's own still is" do
    other = Budget.create!(family: families(:empty), start_date: Date.new(2024, 3, 1), end_date: Date.new(2024, 3, 31),
                           budgeted_spending: 1000, expected_income: 0, currency: "USD")
    assert_nil narrative.budget

    own = create_budget(budgeted: 2000)

    assert_equal own, narrative.budget
    assert_not_equal other, narrative.budget
  end

  # Pace compares spend with the clock, so spend must be through the reference
  # date. A transaction dated after it (scheduled, or entered ahead) is part of
  # the month's budget total but has not happened yet; counting it would call
  # a month "over" before those days arrive.
  test "pace counts spend through the reference date only" do
    create_budget(budgeted: 1000)
    create_transaction(amount: 100, date: Date.new(2024, 3, 5), name: "Past")
    create_transaction(amount: 1500, date: Date.new(2024, 3, 20), name: "Future")
    result = narrative(on: Date.new(2024, 3, 14))

    assert_equal 100, result.pace.spent
    assert_equal :on_track, result.pace.status
    assert_equal 100, result.spent
    # The budget's own full-month figure does include the future entry.
    assert_equal 1600, result.budget.actual_spending
  end

  test "a household budget that the family has switched off is not used" do
    @family.update!(personal_budgets: true, household_budget_enabled: true)
    create_budget(budgeted: 1000)

    assert_not_nil narrative(user: nil, household: true).budget

    @family.update!(household_budget_enabled: false)

    assert_nil narrative(user: nil, household: true).budget
  end

  test "a household budget is still the only budget when the family keeps no personal ones" do
    @family.update!(personal_budgets: false, household_budget_enabled: false)
    budget = create_budget

    assert_equal budget, narrative(user: nil, household: true).budget
    assert_equal budget, narrative.budget
  end

  test "asking for the household budget picks it over the viewer's own, and falls back to theirs when it is off" do
    @family.update!(personal_budgets: true)
    household = create_budget(budgeted: 1000)
    personal = create_budget(user: @user, budgeted: 2000)

    assert_equal household, narrative(household: true).budget
    assert_equal personal, narrative.budget

    @family.update!(household_budget_enabled: false)

    assert_equal personal, narrative(household: true).budget
  end

  # One account scope for every figure. A personal budget counts the owner's
  # own accounts; the viewer's finance accounts also include accounts shared
  # with them, so spending on a shared account is outside the budget's pace.
  test "pace and movers read through the budget's account scope, not the viewer's" do
    @family.update!(personal_budgets: true)
    create_budget(user: @user, budgeted: 1000)
    member = users(:family_member)
    shared = Account.create!(family: @family, owner: member, name: "Shared in", balance: 0, currency: "USD", accountable: Depository.new)
    AccountShare.create!(account: shared, user: @user, permission: "read_only", include_in_finances: true)
    assert_includes @user.finance_accounts.pluck(:id), shared.id, "precondition: the viewer counts the shared account"
    category = @family.categories.create!(name: "Narrative shared", color: "#101010", lucide_icon: "circle")
    create_transaction(account: shared, category: category, amount: 400, date: Date.new(2024, 3, 5), name: "Shared spend")
    result = narrative

    assert_equal 0, result.pace.spent
    assert_empty result.top_movers.select { |m| m.category.id == category.id }
    assert_equal 0, result.previous_spend
    # The viewer's own scope would have counted it.
    assert_equal 400, @family.income_statement(user: @user).net_category_totals(period: result.period).total_net_expense
  end

  test "previous spend is the net spend of the previous window, and zero when there is none" do
    category = @family.categories.create!(name: "Narrative prior", color: "#101010", lucide_icon: "circle")

    assert_equal 0, narrative.previous_spend

    create_transaction(category: category, amount: 300, date: narrative.previous_period.start_date, name: "Prior")
    create_transaction(category: category, amount: 999, date: narrative.period.start_date, name: "Current")

    assert_equal 300, narrative.previous_spend
  end

  # The household budget counts what its viewer can see, so the same budget
  # gives a member who does not count an account in their finances a smaller
  # spend than the owner of that account.
  test "the household budget's spend is read for the viewer" do
    create_budget(budgeted: 1000)
    member = users(:family_member)
    private_account = Account.create!(family: @family, owner: @user, name: "Admin only", balance: 0, currency: "USD", accountable: Depository.new)
    assert_not_includes member.finance_accounts.pluck(:id), private_account.id
    create_transaction(account: private_account, amount: 400, date: Date.new(2024, 3, 5), name: "Private")

    as_owner = narrative(user: @user)
    as_member = narrative(user: member)

    assert_equal as_owner.budget, as_member.budget
    assert_equal 400, as_owner.spent
    assert_equal 0, as_member.spent
  end

  # Without a budget the viewer's own scope applies: a member who does not count
  # an account in their finances sees none of its spending.
  test "without a budget, spend and the movers count only the viewer's accounts" do
    member = users(:family_member)
    private_account = Account.create!(family: @family, owner: @user, name: "Admin only", balance: 0, currency: "USD", accountable: Depository.new)
    assert_not_includes member.finance_accounts.pluck(:id), private_account.id
    category = @family.categories.create!(name: "Narrative private", color: "#101010", lucide_icon: "circle")
    create_transaction(account: private_account, category: category, amount: 400, date: Date.new(2024, 3, 5), name: "Private")

    as_owner = narrative(user: @user)
    as_member = narrative(user: member)

    assert_nil as_owner.budget
    assert_equal 400, as_owner.spent
    assert_equal [ 400 ], as_owner.top_movers.select { |m| m.category.id == category.id }.map { |m| m.delta.to_i }
    assert_equal 0, as_member.spent
    assert_empty as_member.top_movers.select { |m| m.category.id == category.id }
  end
end
