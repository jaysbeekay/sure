require "test_helper"

RakeTaskTestHelper.load_task("portfolio:verify_contract_coverage", "portfolio")

class PortfolioTaskTest < ActiveSupport::TestCase
  PORTFOLIO_TASKS = %w[portfolio:verify_contract_coverage].freeze

  setup do
    RakeTaskTestHelper.prepare(PORTFOLIO_TASKS)
  end

  test "every portfolio task carries exactly one action" do
    doubled = PORTFOLIO_TASKS.select { |name| Rake::Task[name].actions.length != 1 }

    assert_empty doubled, "these tasks have been defined more than once: #{doubled.join(', ')}"
  end

  # Both counts rather than one number: the task's job is to run BOTH gates, and
  # a bare \d+ would still pass if one of them silently stopped being called.
  test "contract coverage task verifies the methodology and returns contracts against existing tests" do
    output, = capture_io { Rake::Task["portfolio:verify_contract_coverage"].invoke }

    assert_match(/Verified \d+ methodology and \d+ returns contract rows against existing tests/, output)
  end

  test "contract coverage task aborts with the first problem found" do
    Portfolio::ContractCoverage.any_instance.stubs(:verify!).raises(Portfolio::ContractCoverage::Error, "P7: missing test \"gone\"")

    error = assert_raises(SystemExit) do
      capture_io { Rake::Task["portfolio:verify_contract_coverage"].invoke }
    end

    assert_not error.success?
  end

  # The returns gate must abort the same way. Its Error is an alias of
  # ContractCoverage::Error so one rescue covers both; if that alias were ever
  # replaced by a separate class, the task would crash with a backtrace instead
  # of reporting the row, and only this test would notice.
  test "contract coverage task aborts on a returns-contract problem too" do
    Portfolio::ReturnsContractCoverage.any_instance
      .stubs(:verify!).raises(Portfolio::ReturnsContractCoverage::Error, "R7: missing test \"gone\"")

    error = assert_raises(SystemExit) do
      capture_io { Rake::Task["portfolio:verify_contract_coverage"].invoke }
    end

    assert_not error.success?
  end
end
