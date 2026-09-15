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
end
