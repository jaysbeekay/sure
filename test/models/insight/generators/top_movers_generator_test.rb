require "test_helper"

class Insight::Generators::TopMoversGeneratorTest < ActiveSupport::TestCase
  include EntriesTestHelper

  # On 14 March 2024 the period is 1-14 March and the window before it is
  # 16-29 February (2024 is a leap year): fourteen days each. No fixture entry
  # lands this far back.
  TODAY = Date.new(2024, 3, 14)
  CURRENT_DAY = Date.new(2024, 3, 3)
  PREVIOUS_DAY = Date.new(2024, 2, 20)

  setup do
    @family = families(:dylan_family)
    @dining = category("Mover Dining")
    @travel = category("Mover Travel")
    @fuel = category("Mover Fuel")
    @shopping = category("Mover Shopping")
  end

  def category(name)
    @family.categories.create!(name: name, color: "#101010", lucide_icon: "circle")
  end

  def spend(category, amount, date)
    create_transaction(category: category, amount: amount, date: date, name: "#{category.name} #{amount}")
  end

  # The comparison window must hold some spending or every category is "new",
  # which says nothing; most tests need it. Shopping spends the same in both
  # windows, so it is a baseline and never a mover itself.
  def seed_baseline
    spend(@shopping, 400, PREVIOUS_DAY)
    spend(@shopping, 400, CURRENT_DAY)
  end

  def generate(on: TODAY, family: @family)
    Insight::Generators::TopMoversGenerator.new(family, today: on).generate
  end

  test "reports the category that rose most" do
    seed_baseline
    spend(@dining, 100, PREVIOUS_DAY)
    spend(@dining, 300, CURRENT_DAY)

    insights = generate

    assert_equal 1, insights.size
    insight = insights.first
    assert_equal "top_movers", insight.insight_type
    assert_equal "top_movers.up", insight.template_key
    assert_equal "Mover Dining", insight.facts[:top_category]
    assert_equal "$200.00", insight.facts[:top_change]
    assert_equal 14, insight.facts[:days]
    assert_equal "up", insight.metadata[:direction]
  end

  test "reports a fall when the biggest mover fell" do
    seed_baseline
    spend(@travel, 900, PREVIOUS_DAY)
    spend(@travel, 100, CURRENT_DAY)

    insight = generate.first

    assert_equal "top_movers.down", insight.template_key
    assert_equal "down", insight.metadata[:direction]
    assert_equal "$800.00", insight.facts[:top_change]
  end

  test "lists up to three categories that moved the same way as the biggest, largest first" do
    seed_baseline
    spend(@dining, 300, CURRENT_DAY)    # +300
    spend(@travel, 200, CURRENT_DAY)    # +200
    spend(@fuel, 100, CURRENT_DAY)      # +100
    spend(@shopping, 300, CURRENT_DAY)  # +300 on top of the 400 baseline
    spend(@dining, 1, CURRENT_DAY)      # dining +301, the clear leader

    insight = generate.first

    assert_equal "Mover Dining, Mover Shopping, and Mover Travel", insight.facts[:categories]
    assert_equal 3, insight.metadata[:category_ids].size
  end

  # Uncategorised spend has no category id. Listed next to a real category it
  # used to make the metadata sort raise, which the registry logs and skips: one
  # synthetic bucket silently suppressed the whole insight.
  test "an uncategorised bucket among the listed movers does not break the insight" do
    seed_baseline
    spend(@dining, 300, CURRENT_DAY)                                   # +300
    create_transaction(amount: 200, date: CURRENT_DAY, name: "No category") # uncategorised +200

    insights = nil
    assert_nothing_raised { insights = generate }

    insight = insights.first
    assert_equal "Mover Dining and Uncategorized", insight.facts[:categories]
    assert_equal 2, insight.metadata[:category_ids].size
    assert_includes insight.metadata[:category_ids], @dining.id
    assert_includes insight.metadata[:category_ids], "uncategorized"
    assert insight.metadata[:category_ids].all? { |id| id.is_a?(String) }
  end

  test "a mover that went the other way is not listed under the biggest mover's direction" do
    seed_baseline
    spend(@travel, 400, PREVIOUS_DAY)         # travel: 400 -> 0, a fall of 400
    spend(@dining, 800, CURRENT_DAY)          # +800, the biggest

    insight = generate.first

    assert_equal "Mover Dining", insight.facts[:categories]
  end

  # Both thresholds are tested at the line and one step either side of it.
  test "ignores a change under the minimum amount and reports one at it" do
    seed_baseline
    spend(@dining, 49, CURRENT_DAY)
    assert_empty generate

    spend(@dining, 1, CURRENT_DAY)
    assert_equal 1, generate.size
  end

  test "ignores a change under 25 percent of the prior spend and reports one at it" do
    spend(@dining, 1000, PREVIOUS_DAY)
    spend(@dining, 1249, CURRENT_DAY)
    assert_empty generate

    spend(@dining, 1, CURRENT_DAY)
    assert_equal 1, generate.size
  end

  test "a brand new category has no percentage to fail and is reported" do
    seed_baseline
    spend(@dining, 60, CURRENT_DAY)

    insight = generate.first

    assert_equal "Mover Dining", insight.facts[:top_category]
    assert_equal "new", insight.metadata[:change_bucket]
  end

  test "is skipped until a week of the month has gone, and speaks on the seventh day" do
    # Day 6: period 1-6 March, previous window 24-29 February.
    spend(@shopping, 400, Date.new(2024, 2, 27))
    spend(@shopping, 400, Date.new(2024, 3, 2))
    spend(@dining, 300, Date.new(2024, 3, 2))

    assert_empty generate(on: Date.new(2024, 3, 6))
    assert_equal 1, generate(on: Date.new(2024, 3, 7)).size
  end

  test "is skipped when the comparison window has no spending at all" do
    spend(@dining, 300, CURRENT_DAY)

    assert_empty generate
  end

  test "dedupes per month: one key for the month, a new one next month" do
    seed_baseline
    spend(@dining, 300, CURRENT_DAY)
    # April: period 1-14 April, previous window 18-31 March.
    spend(@shopping, 400, Date.new(2024, 3, 25))
    spend(@shopping, 400, Date.new(2024, 4, 3))
    spend(@dining, 300, Date.new(2024, 4, 3))

    march_a = generate(on: Date.new(2024, 3, 14)).first
    march_b = generate(on: Date.new(2024, 3, 20)).first
    april = generate(on: Date.new(2024, 4, 14)).first

    assert_equal "top_movers:2024-03", march_a.dedup_key
    assert_equal march_a.dedup_key, march_b.dedup_key
    assert_equal "top_movers:2024-04", april.dedup_key
  end

  test "metadata holds still for small changes in the biggest mover and moves with the direction" do
    seed_baseline
    spend(@dining, 1000, PREVIOUS_DAY)
    spend(@dining, 1500, CURRENT_DAY)      # +50%
    baseline = generate.first.metadata

    spend(@dining, 20, CURRENT_DAY)        # +52%: same 25-point bucket
    assert_equal baseline, generate.first.metadata

    spend(@dining, 300, CURRENT_DAY)       # +82%: next bucket
    assert_not_equal baseline, generate.first.metadata
  end

  test "another family's spending never shows up" do
    other = families(:empty)
    account = Account.create!(family: other, name: "Other", balance: 0, currency: "USD", accountable: Depository.new)
    other_category = other.categories.create!(name: "Other family mover", color: "#101010", lucide_icon: "circle")
    Entry.create!(account: account, name: "Prev", date: PREVIOUS_DAY, currency: "USD", amount: 400, entryable: Transaction.new(category: other_category))
    Entry.create!(account: account, name: "Cur", date: CURRENT_DAY, currency: "USD", amount: 9000, entryable: Transaction.new(category: other_category))

    assert_empty generate
    assert_equal 1, generate(family: other).size
  end

  test "carries the period of the comparison and is registered" do
    seed_baseline
    spend(@dining, 300, CURRENT_DAY)

    insight = generate.first

    assert_equal Date.new(2024, 3, 1), insight.period_start
    assert_equal TODAY, insight.period_end
    assert_includes Insight::GeneratorRegistry::GENERATORS, Insight::Generators::TopMoversGenerator
    assert_equal [ "top_movers" ], Insight::Generators::TopMoversGenerator.produced_types
    assert_includes Insight::TYPES, "top_movers"
  end
end
