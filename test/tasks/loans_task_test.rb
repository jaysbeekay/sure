require "test_helper"

load Rails.root.join("lib/tasks/loans.rake")

class LoansTaskTest < ActiveSupport::TestCase
  setup do
    Rake::Task["loans:amortization_variance"].clear_prerequisites
  end

  test "variance task writes a non-mutating monthly versus daily report" do
    output = Rails.root.join("tmp", "loan-variance-test.csv")
    FileUtils.rm_f(output)

    Rake::Task["loans:amortization_variance"].reenable
    Rake::Task["loans:amortization_variance"].invoke("1", output.to_s)

    rows = CSV.read(output, headers: true)
    assert_equal 1, rows.length
    assert_equal %w[loan_id monthly_interest daily_interest interest_delta monthly_cost daily_cost cost_delta monthly_converged daily_converged], rows.headers
    assert_equal "true", rows.first["monthly_converged"]
    assert_equal "true", rows.first["daily_converged"]
  ensure
    FileUtils.rm_f(output)
  end
end
