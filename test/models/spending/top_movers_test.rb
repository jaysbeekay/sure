require "test_helper"

class Spending::TopMoversTest < ActiveSupport::TestCase
  include EntriesTestHelper

  # A fixed past window: no fixture entry lands in it, so every figure below is
  # the one the test created.
  CURRENT = Period.custom(start_date: Date.new(2024, 3, 11), end_date: Date.new(2024, 3, 20))
  PREVIOUS = Period.custom(start_date: Date.new(2024, 3, 1), end_date: Date.new(2024, 3, 10))

  setup do
    @family = families(:dylan_family)
    @dining = category("Narrative Dining")
    @travel = category("Narrative Travel")
    @fuel = category("Narrative Fuel")
  end

  def category(name)
    @family.categories.create!(name: name, color: "#101010", lucide_icon: "circle")
  end

  def spend(category, amount, date)
    create_transaction(category: category, amount: amount, date: date, name: "#{category.name} #{date}")
  end

  def movers(limit: 10)
    Spending::TopMovers.new(income_statement: @family.income_statement(user: nil), period: CURRENT, previous_period: PREVIOUS).movers(limit: limit)
  end

  def mover_for(category, limit: 10)
    movers(limit: limit).find { |m| m.category.id == category.id }
  end

  test "ranks categories by the size of the change, in either direction" do
    spend(@dining, 100, PREVIOUS.start_date)
    spend(@dining, 160, CURRENT.start_date)   # +60
    spend(@travel, 500, PREVIOUS.start_date)
    spend(@travel, 100, CURRENT.start_date)   # -400
    spend(@fuel, 50, PREVIOUS.start_date)
    spend(@fuel, 130, CURRENT.start_date)     # +80

    ours = movers.select { |m| [ @dining, @travel, @fuel ].map(&:id).include?(m.category.id) }

    assert_equal [ @travel, @fuel, @dining ].map(&:id), ours.map { |m| m.category.id }
    assert_equal [ -400, 80, 60 ], ours.map { |m| m.delta.to_i }
    assert_equal %i[down up up], ours.map(&:direction)
  end

  test "a category with no spend in the prior period is new and has no percentage" do
    spend(@dining, 200, CURRENT.start_date)

    mover = mover_for(@dining)

    assert_equal 200, mover.delta
    assert_equal 0, mover.previous
    assert mover.new?
    assert_nil mover.change_pct
  end

  test "a category with no spend in the current period is gone and fell by all of it" do
    spend(@travel, 300, PREVIOUS.start_date)

    mover = mover_for(@travel)

    assert_equal(-300, mover.delta)
    assert_equal 0, mover.current
    assert mover.gone?
    assert_equal(-100, mover.change_pct)
  end

  test "reports the percentage change against the prior period" do
    spend(@dining, 200, PREVIOUS.start_date)
    spend(@dining, 250, CURRENT.start_date)

    mover = mover_for(@dining)

    assert_equal 25, mover.change_pct
    assert_not mover.new?
    assert_not mover.gone?
  end

  test "a category that did not change is not a mover" do
    spend(@dining, 200, PREVIOUS.start_date)
    spend(@dining, 200, CURRENT.start_date)

    assert_nil mover_for(@dining)
  end

  # A refund nets against the spend in its own category, the same way the budget
  # and the heatmap net it; gross spend would report +150 here.
  test "refunds reduce the current figure" do
    spend(@dining, 200, PREVIOUS.start_date)
    spend(@dining, 350, CURRENT.start_date)
    spend(@dining, -50, CURRENT.start_date + 1)

    mover = mover_for(@dining)

    assert_equal 300, mover.current
    assert_equal 100, mover.delta
  end

  test "a category refunded beyond its spend counts as zero, not as a negative mover" do
    spend(@dining, 200, PREVIOUS.start_date)
    spend(@dining, 50, CURRENT.start_date)
    spend(@dining, -80, CURRENT.start_date + 1)

    mover = mover_for(@dining)

    assert_equal 0, mover.current
    assert_equal(-200, mover.delta)
    assert mover.gone?
  end

  test "limit keeps the biggest movers" do
    spend(@dining, 100, CURRENT.start_date)
    spend(@travel, 900, CURRENT.start_date)
    spend(@fuel, 400, CURRENT.start_date)

    top = movers(limit: 2)

    assert_equal 2, top.size
    assert_equal [ @travel.id, @fuel.id ], top.map { |m| m.category.id }.first(2)
  end

  test "another family's spending never shows up" do
    other = families(:empty)
    account = Account.create!(family: other, name: "Other checking", balance: 0, currency: "USD", accountable: Depository.new)
    other_category = other.categories.create!(name: "Other family dining", color: "#101010", lucide_icon: "circle")
    Entry.create!(account: account, name: "Other", date: CURRENT.start_date, currency: "USD", amount: 999,
                  entryable: Transaction.new(category: other_category))
    spend(@dining, 100, CURRENT.start_date)

    all = movers

    assert_not_includes all.map { |m| m.category.id }, other_category.id
    assert_equal 100, all.find { |m| m.category.id == @dining.id }.delta
  end

  test "previous_period is the period of equal length ending the day before" do
    previous = Spending::TopMovers.previous_period(CURRENT)

    assert_equal PREVIOUS.start_date, previous.start_date
    assert_equal PREVIOUS.end_date, previous.end_date
    assert_equal CURRENT.days, previous.days
  end
end
