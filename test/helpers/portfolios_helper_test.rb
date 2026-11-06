require "test_helper"

class PortfoliosHelperTest < ActionView::TestCase
  include PortfoliosHelper

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
