require "test_helper"

class PortfoliosHelperTest < ActionView::TestCase
  include PortfoliosHelper

  test "allocation colours come from the shared chart palette and wrap around" do
    assert_equal Category::COLORS.first, allocation_color(0)
    assert_equal Category::COLORS.first, allocation_color(Category::COLORS.size)
    assert_equal Category::COLORS.last, allocation_color(Category::COLORS.size - 1)
  end

  test "allocation segments serialise to the donut chart's contract" do
    segment = InvestmentStatement.const_get(:AllocationSegment).new(id: "USD", name: "USD", amount: Money.new(1234.567, "USD"), weight: 61.234)

    json = JSON.parse(allocation_segments_json([ segment ], currency: "USD"))

    assert_equal [ { "id" => "USD", "name" => "USD", "amount" => 1234.57, "currency" => "USD", "percentage" => 61.2, "color" => Category::COLORS.first } ], json
  end

  # The period-return card's hint. Three branches a regression would break
  # silently: the plain label when nothing was excluded, the singular and
  # plural disclosure, and the concatenation that keeps the comparison label
  # in front of it.
  class KpiPeriodReturnHintTest < ActionView::TestCase
    include PortfoliosHelper

    setup { @period = Period.current_month }

    test "no disclosure when everything converted" do
      assert_equal @period.comparison_label, kpi_period_return_hint(@period, 0)
      assert_equal @period.comparison_label, kpi_period_return_hint(@period, nil)
    end

    test "one excluded account reads in the singular" do
      hint = kpi_period_return_hint(@period, 1)

      assert_includes hint, @period.comparison_label, "the comparison label was dropped"
      assert_match(/1 account/, hint)
      assert_no_match(/accounts/, hint, "singular count used the plural string")
    end

    test "more than one reads in the plural, with the count" do
      hint = kpi_period_return_hint(@period, 3)

      assert_includes hint, @period.comparison_label
      assert_match(/3 accounts/, hint)
    end
  end
end
