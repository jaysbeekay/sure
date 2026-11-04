# frozen_string_literal: true

require "test_helper"

class Loan::AmortizationReportTest < ActiveSupport::TestCase
  test "the next rate change is the first after the date it is given" do
    loan = loans(:one)
    loan.update_columns(rate_type: "variable", start_date: Date.new(2024, 1, 1),
                        variable_rate_schedule: { "2025-01-01" => "5.5", "2026-01-01" => "6.0" })
    report = Loan::AmortizationReport.new(loan.reload)

    assert_equal Date.new(2025, 1, 1), report.next_rate_change_date(as_of: Date.new(2024, 6, 1))
    assert_equal Date.new(2026, 1, 1), report.next_rate_change_date(as_of: Date.new(2025, 1, 1))
    assert_nil report.next_rate_change_date(as_of: Date.new(2026, 1, 1))
  end
end
