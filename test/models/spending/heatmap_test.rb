require "test_helper"

class Spending::HeatmapTest < ActiveSupport::TestCase
  include EntriesTestHelper

  # March 2024 starts on a Friday and ends on a Sunday, so with Sunday-first
  # weeks it spans six rows, the first and last only partly inside the period.
  # No fixture entry lands this far back, so every figure is one the test made.
  PERIOD = Period.custom(start_date: Date.new(2024, 3, 1), end_date: Date.new(2024, 3, 31))

  setup do
    @family = families(:dylan_family)
    @dining = category("Heat Dining")
    @dining_out = category("Heat Dining Out", parent: @dining)
    @travel = category("Heat Travel")
    @salary = category("Heat Salary")
  end

  def category(name, parent: nil)
    @family.categories.create!(name: name, color: "#101010", lucide_icon: "circle", parent: parent)
  end

  def spend(amount, date, category: nil, account: accounts(:depository), **attrs)
    create_transaction(account: account, category: category, amount: amount, date: date, name: "heat #{date}", **attrs)
  end

  def heatmap(user: nil, family: @family, period: PERIOD)
    Spending::Heatmap.new(income_statement: family.income_statement(user: user), period: period)
  end

  def cell(map, date)
    map.weeks.flat_map(&:cells).compact.find { |c| c.date == date }
  end

  # One month with everything the budget would and would not count.
  def seed_month
    spend(100, Date.new(2024, 3, 4), category: @dining)       # Monday
    spend(40, Date.new(2024, 3, 5), category: @dining)
    spend(-30, Date.new(2024, 3, 6), category: @dining)       # a refund
    spend(20, Date.new(2024, 3, 4), category: @dining_out)    # rolls into Dining
    spend(300, Date.new(2024, 3, 9), category: @travel)       # Saturday
    spend(15, Date.new(2024, 3, 20))                          # uncategorised
    spend(-2000, Date.new(2024, 3, 15), category: @salary)    # income, not a refund
    # None of these count towards spending:
    spend(999, Date.new(2024, 3, 12), category: @travel, excluded: true)
    create_transfer(from_account: accounts(:depository), to_account: accounts(:credit_card), amount: 500, date: Date.new(2024, 3, 13))
    hidden = Account.create!(family: @family, name: "Hidden", balance: 0, currency: "USD", accountable: Depository.new, exclude_from_reports: true)
    spend(777, Date.new(2024, 3, 14), category: @travel, account: hidden)
  end

  # The consistency the page rests on: the grid, the budget and the movers all
  # describe one number. Assert it against the budget's own figure and against a
  # total worked out by hand, so a wrong formula cannot agree with itself.
  test "cell totals add up to the period's net expense, which is the budget's figure" do
    seed_month
    map = heatmap

    assert_equal 445, map.total                       # 130 dining + 300 travel + 15 uncategorised
    assert_equal map.total, map.weeks.flat_map(&:cells).compact.sum(&:total)
    assert_equal @family.income_statement(user: nil).net_category_totals(period: PERIOD).total_net_expense, map.total
  end

  test "a refund nets against spending on the day it lands" do
    spend(100, Date.new(2024, 3, 4), category: @dining)
    before = heatmap
    refund_day_before = cell(before, Date.new(2024, 3, 6)).total
    total_before = before.total

    spend(-30, Date.new(2024, 3, 6), category: @dining)
    after = heatmap

    assert_equal 0, refund_day_before
    assert_equal(-30, cell(after, Date.new(2024, 3, 6)).total)
    assert_equal 30, total_before - after.total
  end

  test "a subcategory's spend lands in the same cell as its parent's" do
    spend(100, Date.new(2024, 3, 4), category: @dining)
    spend(20, Date.new(2024, 3, 4), category: @dining_out)

    assert_equal 120, cell(heatmap, Date.new(2024, 3, 4)).total
  end

  test "income with no spend in its category is not netted against spending" do
    spend(50, Date.new(2024, 3, 4), category: @dining)
    spend(-2000, Date.new(2024, 3, 4), category: @salary)

    assert_equal 50, cell(heatmap, Date.new(2024, 3, 4)).total
  end

  test "transfers, excluded entries and accounts excluded from reports add nothing" do
    seed_month
    baseline = heatmap.total

    spend(1, Date.new(2024, 3, 20))

    assert_equal baseline + 1, heatmap.total
    assert_equal 0, cell(heatmap, Date.new(2024, 3, 12)).total
    assert_equal 0, cell(heatmap, Date.new(2024, 3, 13)).total
    assert_equal 0, cell(heatmap, Date.new(2024, 3, 14)).total
  end

  # Spend and a refund of the same amount net to nothing, which the budget
  # treats as no spending at all: the category must leave the grid, not show a
  # positive day and a negative one.
  test "a category refunded exactly to zero leaves no trace in the grid" do
    spend(50, Date.new(2024, 3, 4), category: @dining)
    spend(-50, Date.new(2024, 3, 6), category: @dining)

    assert_equal 0, cell(heatmap, Date.new(2024, 3, 4)).total
    assert_equal 0, cell(heatmap, Date.new(2024, 3, 6)).total
    assert_equal 0, heatmap.total
  end

  # entries.excluded is nullable, and the income statement's `excluded = false`
  # drops a NULL row. The grid must drop it too: its total is meant to equal the
  # budget's, and a row one counts and the other does not breaks that.
  test "an entry whose excluded flag is NULL is treated as the income statement treats it" do
    spend(100, Date.new(2024, 3, 4), category: @dining)
    odd = spend(70, Date.new(2024, 3, 5), category: @dining)
    odd.update_column(:excluded, nil)

    statement_total = @family.income_statement(user: nil).net_category_totals(period: PERIOD).total_net_expense

    assert_equal statement_total, heatmap.total
  end

  test "pending transactions add nothing, as in the income statement" do
    spend(100, Date.new(2024, 3, 4), category: @dining)
    posted = heatmap.total

    Entry.create!(account: accounts(:depository), name: "Pending", date: Date.new(2024, 3, 5), currency: "USD", amount: 70,
                  entryable: Transaction.new(category: @dining, extra: { "simplefin" => { "pending" => true } }))

    assert_equal posted, heatmap.total
    assert_equal @family.income_statement(user: nil).net_category_totals(period: PERIOD).total_net_expense, heatmap.total
  end

  test "one-time and credit-card-payment kinds add nothing, as in the budget" do
    spend(100, Date.new(2024, 3, 4), category: @dining)
    posted = heatmap.total

    spend(300, Date.new(2024, 3, 5), category: @dining, kind: "one_time")
    spend(400, Date.new(2024, 3, 5), category: @dining, kind: "cc_payment")

    assert_equal posted, heatmap.total
  end

  test "places each date in its weekday column and its week row" do
    map = heatmap

    assert_equal 6, map.weeks.size
    # Fri 1 Mar is the last column of the first row; Sun 31 Mar the first of the last.
    assert_equal Date.new(2024, 3, 1), map.weeks.first.cells[5].date
    assert_equal Date.new(2024, 3, 31), map.weeks.last.cells[0].date
    # Mon 4 Mar opens the second row; Sat 9 Mar closes it.
    assert_equal Date.new(2024, 3, 4), map.weeks.second.cells[1].date
    assert_equal Date.new(2024, 3, 9), map.weeks.second.cells[6].date
  end

  test "days outside the period are empty cells, not zero-spend days" do
    map = heatmap

    assert_equal [ nil, nil, nil, nil, nil ], map.weeks.first.cells.first(5)
    assert_equal [ nil ] * 6, map.weeks.last.cells.drop(1)
  end

  test "each week row reports the part of its week inside the period" do
    map = heatmap

    assert_equal [ Date.new(2024, 3, 1), Date.new(2024, 3, 2) ], [ map.weeks.first.start_date, map.weeks.first.end_date ]
    assert_equal [ Date.new(2024, 3, 3), Date.new(2024, 3, 9) ], [ map.weeks.second.start_date, map.weeks.second.end_date ]
    assert_equal [ Date.new(2024, 3, 31), Date.new(2024, 3, 31) ], [ map.weeks.last.start_date, map.weeks.last.end_date ]
  end

  test "weekday totals add up to the total" do
    seed_month
    map = heatmap

    assert_equal 7, map.weekday_totals.size
    assert_equal map.total, map.weekday_totals.sum
    assert_equal 120, map.weekday_totals[1]            # Mondays: the 4th
    assert_equal 300, map.weekday_totals[6]            # Saturdays: the 9th
  end

  test "an empty period is all zeros and has no peak" do
    map = heatmap

    assert_equal 0, map.total
    assert_equal 0, map.peak
  end

  test "peak is the biggest single day" do
    seed_month

    assert_equal 300, heatmap.peak
  end

  test "another family's spending never shows up" do
    other = families(:empty)
    account = Account.create!(family: other, name: "Other checking", balance: 0, currency: "USD", accountable: Depository.new)
    other_category = other.categories.create!(name: "Other heat", color: "#101010", lucide_icon: "circle")
    Entry.create!(account: account, name: "Other", date: Date.new(2024, 3, 4), currency: "USD", amount: 999,
                  entryable: Transaction.new(category: other_category))
    spend(100, Date.new(2024, 3, 4), category: @dining)

    assert_equal 100, heatmap.total
    assert_equal 999, heatmap(family: other).total
  end

  test "scopes to the accounts the user counts in their finances, like the income statement" do
    admin = users(:family_admin)
    member = users(:family_member)
    private_account = Account.create!(family: @family, owner: admin, name: "Admin only", balance: 0, currency: "USD", accountable: Depository.new)
    assert_not_includes member.finance_accounts.pluck(:id), private_account.id,
      "precondition: the member does not count this account in their finances"
    spend(100, Date.new(2024, 3, 4), category: @dining, account: private_account)

    assert_equal 0, heatmap(user: member).total
    assert_equal @family.income_statement(user: member).net_category_totals(period: PERIOD).total_net_expense, heatmap(user: member).total
    assert_equal 100, heatmap(user: admin).total
  end
end
