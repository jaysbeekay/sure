require "test_helper"

class SpendingNarrativesHelperTest < ActionView::TestCase
  include EntriesTestHelper

  PERIOD = Period.custom(start_date: Date.new(2024, 3, 1), end_date: Date.new(2024, 3, 14))

  def query(path)
    Rack::Utils.parse_nested_query(URI.parse(path).query).fetch("q")
  end

  # Heat is quartiles of the peak, and the boundary sits on the upper edge of
  # each band: exactly a quarter of the peak is still the first band.
  test "heat level steps at quarters of the peak, on both sides of each step" do
    peak = 100.to_d

    assert_equal 0, spending_heat_level(0, peak)
    assert_equal 1, spending_heat_level("0.01".to_d, peak)
    assert_equal 1, spending_heat_level(25, peak)
    assert_equal 2, spending_heat_level("25.01".to_d, peak)
    assert_equal 2, spending_heat_level(50, peak)
    assert_equal 3, spending_heat_level("50.01".to_d, peak)
    assert_equal 3, spending_heat_level(75, peak)
    assert_equal 4, spending_heat_level("75.01".to_d, peak)
    assert_equal 4, spending_heat_level(100, peak)
  end

  test "a refund day and an empty grid are not heated" do
    assert_equal 0, spending_heat_level(-30, 100.to_d)
    assert_equal 0, spending_heat_level(50, 0.to_d)
  end

  test "heat classes are design-system tokens, one per level, none for level zero" do
    classes = (0..4).map { |level| spending_heat_class_for_level(level) }

    assert_nil classes.first
    assert_equal 4, classes.compact.uniq.size
    assert classes.compact.all? { |c| c.match?(/\Abg-warning\/\d+\z/) }, "expected token classes, got #{classes.inspect}"
  end

  test "a category link carries the category and the period's range" do
    category = families(:dylan_family).categories.create!(name: "Click Dining", color: "#101010", lucide_icon: "circle")

    q = query(spending_category_path(category, PERIOD))

    assert_equal [ "Click Dining" ], q["categories"]
    assert_equal "2024-03-01", q["start_date"]
    assert_equal "2024-03-14", q["end_date"]
  end

  test "the uncategorised link uses the stable sentinel, not the translated name" do
    q = query(spending_category_path(Category.uncategorized, PERIOD))

    assert_equal [ Category::UNCATEGORIZED_FILTER_VALUE ], q["categories"]
  end

  test "other investments has no transaction filter, so it has no link" do
    assert_nil spending_category_path(Category.other_investments, PERIOD)
  end

  test "a date range link carries only the range" do
    q = query(spending_range_path(Date.new(2024, 3, 4), Date.new(2024, 3, 4)))

    assert_equal({ "start_date" => "2024-03-04", "end_date" => "2024-03-04" }, q)
  end

  test "pace status picks a tone" do
    assert_equal :success, spending_pace_tone(OpenStruct.new(status: :on_track))
    assert_equal :warning, spending_pace_tone(OpenStruct.new(status: :approaching))
    assert_equal :error, spending_pace_tone(OpenStruct.new(status: :over))
  end

  test "a change label signs the amount and the percentage, and says new when there is no prior spend" do
    Current.stubs(:family).returns(families(:dylan_family))
    category = Category.new(name: "x")
    up = Spending::TopMovers::Mover.new(category: category, current: 250.to_d, previous: 200.to_d)
    down = Spending::TopMovers::Mover.new(category: category, current: 100.to_d, previous: 400.to_d)
    fresh = Spending::TopMovers::Mover.new(category: category, current: 60.to_d, previous: 0.to_d)

    assert_equal "+$50.00 (+25%)", spending_change_label(up)
    assert_equal "−$300.00 (−75%)", spending_change_label(down)
    assert_equal "+$60.00 (#{I18n.t("spending_narratives.movers.new")})", spending_change_label(fresh)
  end

  test "heatmap rows: one per week, then the weekday totals; every cell links to its own day" do
    family = families(:dylan_family)
    category = family.categories.create!(name: "Row Dining", color: "#101010", lucide_icon: "circle")
    create_transaction(category: category, amount: 80, date: Date.new(2024, 3, 4), name: "Mon")
    create_transaction(category: category, amount: 20, date: Date.new(2024, 3, 6), name: "Wed")
    heatmap = Spending::Heatmap.new(income_statement: family.income_statement(user: nil), period: PERIOD)

    rows = spending_heatmap_rows(heatmap)

    assert_equal heatmap.weeks.size + 1, rows.size
    monday_cell = rows.second.cells[1]
    assert_equal 80, monday_cell.total
    assert_equal 4, monday_cell.level
    assert_equal({ "start_date" => "2024-03-04", "end_date" => "2024-03-04" }, query(monday_cell.href))
    # A day with nothing spent is plain text, and a date outside the period is no cell at all.
    assert_nil rows.second.cells[2].href
    assert_nil rows.first.cells.first
    # Each week row links to its own range and carries its own total.
    assert_equal 100, rows.second.total.total
    assert_equal({ "start_date" => "2024-03-03", "end_date" => "2024-03-09" }, query(rows.second.href))
    # The last row is the weekday totals; its total is the whole period's.
    assert_equal [ 0, 80, 0, 20, 0, 0, 0 ], rows.last.cells.map { |c| c.total.to_i }
    assert_equal 100, rows.last.total.total
    assert_equal 4, rows.last.cells[1].level
  end
end
