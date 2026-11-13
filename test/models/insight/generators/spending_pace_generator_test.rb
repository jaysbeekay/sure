require "test_helper"

class Insight::Generators::SpendingPaceGeneratorTest < ActiveSupport::TestCase
  include EntriesTestHelper

  # March 2024 has 31 days. A month no fixture touches, with the reference date
  # injected so nothing below depends on today.
  MONTH = Date.new(2024, 3, 1)

  setup do
    @family = families(:dylan_family)
  end

  def create_budget(budgeted: 1000, start_date: MONTH, family: @family)
    Budget.create!(family: family, start_date: start_date, end_date: start_date.end_of_month,
                   budgeted_spending: budgeted, expected_income: 0, currency: "USD")
  end

  def spend(amount, date = MONTH + 1)
    create_transaction(amount: amount, date: date, name: "Pace #{amount}")
  end

  def generate(on:)
    Insight::Generators::SpendingPaceGenerator.new(@family, today: on).generate
  end

  test "flags a budget that is already over, however early in the month" do
    create_budget
    spend(1001)

    insights = generate(on: MONTH + 2) # day 3, below the elapsed-days minimum

    assert_equal 1, insights.size
    assert_equal "spending_pace", insights.first.insight_type
    assert_equal "spending_pace.over", insights.first.template_key
    assert_equal "high", insights.first.priority
  end

  test "spending exactly the whole budget is not over" do
    create_budget
    spend(1000)

    assert_empty generate(on: Date.new(2024, 3, 31))
  end

  test "flags a budget running ahead of pace once there are enough days to project from" do
    create_budget
    spend(500)

    insights = generate(on: Date.new(2024, 3, 14))

    assert_equal 1, insights.size
    assert_equal "spending_pace.approaching", insights.first.template_key
    assert_equal "medium", insights.first.priority
  end

  # 400 of 1000 is far ahead of pace on day 6 and day 7 alike; only the data
  # minimum differs, so only the seventh day may speak.
  test "stays quiet about a projection until the seventh day, and speaks on it" do
    create_budget
    spend(400)

    assert_empty generate(on: Date.new(2024, 3, 6))
    assert_equal 1, generate(on: Date.new(2024, 3, 7)).size
  end

  test "says nothing for a budget that is on track" do
    create_budget
    spend(100)

    assert_empty generate(on: Date.new(2024, 3, 14))
  end

  test "no budget, an unset budget and a zero budget produce nothing and do not raise" do
    assert_empty generate(on: Date.new(2024, 3, 14))

    create_budget(budgeted: nil)
    assert_empty generate(on: Date.new(2024, 3, 14))

    Budget.where(family: @family).update_all(budgeted_spending: 0)
    assert_empty generate(on: Date.new(2024, 3, 14))
  end

  # The viewed family has its own on-track budget, so a leak of the other
  # family's 5,000 would tip it over and the test would see an insight; with no
  # budget at all the generator would exit early and prove nothing.
  test "another family's budget and spending are ignored" do
    create_budget(budgeted: 1000)
    spend(100)
    other = families(:empty)
    create_budget(family: other, budgeted: 10)
    account = Account.create!(family: other, name: "Other", balance: 0, currency: "USD", accountable: Depository.new)
    Entry.create!(account: account, name: "Other", date: MONTH + 1, currency: "USD", amount: 5000, entryable: Transaction.new)

    assert_empty generate(on: Date.new(2024, 3, 14))
    assert_equal 1, Insight::Generators::SpendingPaceGenerator.new(other, today: Date.new(2024, 3, 14)).generate.size
  end

  # The budget's own total is the whole month; the pace is against the clock.
  test "spend dated after the reference date does not make the month look over" do
    create_budget
    spend(100, Date.new(2024, 3, 5))
    spend(1500, Date.new(2024, 3, 20)) # entered ahead of time

    assert_empty generate(on: Date.new(2024, 3, 14))
    assert_equal 1, generate(on: Date.new(2024, 3, 20)).size
  end

  test "a household budget the family has switched off produces nothing" do
    @family.update!(personal_budgets: true, household_budget_enabled: true)
    create_budget
    spend(1500)
    assert_equal 1, generate(on: Date.new(2024, 3, 14)).size

    @family.update!(household_budget_enabled: false)

    assert_empty generate(on: Date.new(2024, 3, 14))
  end

  test "carries the numbers as display facts and the period of the budget" do
    create_budget
    spend(500)

    insight = generate(on: Date.new(2024, 3, 14)).first

    assert_equal "$500.00", insight.facts[:spent]
    assert_equal "$1,000.00", insight.facts[:budgeted]
    assert_equal 50, insight.facts[:spent_pct]
    assert_equal 45, insight.facts[:elapsed_pct]
    assert_equal "$1,107.14", insight.facts[:projected_spend] # 500 * 31 / 14
    assert_equal MONTH, insight.period_start
    assert_equal MONTH.end_of_month, insight.period_end
    assert_equal "USD", insight.currency
  end

  test "an over insight carries how far over the budget is" do
    create_budget
    spend(1250)

    assert_equal "$250.00", generate(on: Date.new(2024, 3, 14)).first.facts[:over_by]
  end

  test "dedupes per month: the key does not move within a month and does move between months" do
    create_budget
    spend(800)
    create_budget(start_date: Date.new(2024, 4, 1))
    create_transaction(amount: 800, date: Date.new(2024, 4, 2), name: "April")

    march_a = generate(on: Date.new(2024, 3, 14)).first
    march_b = generate(on: Date.new(2024, 3, 20)).first
    april = generate(on: Date.new(2024, 4, 14)).first

    assert_equal "spending_pace:2024-03", march_a.dedup_key
    assert_equal march_a.dedup_key, march_b.dedup_key
    assert_equal "spending_pace:2024-04", april.dedup_key
  end

  # Metadata is what the nightly job compares to decide whether to rewrite the
  # body and resurface a dismissed insight, so it must hold still for pennies
  # and move when the story changes.
  test "metadata ignores small movements and changes when the status or the bucket does" do
    create_budget
    spend(500)
    on = Date.new(2024, 3, 14)
    baseline = generate(on: on).first.metadata

    spend(20) # 52%: same ten-point bucket
    same_bucket = generate(on: on).first.metadata

    spend(100) # 62%: next bucket
    next_bucket = generate(on: on).first.metadata

    spend(500) # 112%: over
    over = generate(on: on).first.metadata

    assert_equal baseline, same_bucket
    assert_not_equal baseline, next_bucket
    assert_equal "approaching", baseline[:status]
    assert_equal "over", over[:status]
  end

  test "is registered and declares the type it produces" do
    assert_includes Insight::GeneratorRegistry::GENERATORS, Insight::Generators::SpendingPaceGenerator
    assert_equal [ "spending_pace" ], Insight::Generators::SpendingPaceGenerator.produced_types
    assert_includes Insight::TYPES, "spending_pace"
  end
end
