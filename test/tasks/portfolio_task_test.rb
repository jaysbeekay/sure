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

  test "contract coverage task verifies every methodology row against an existing test" do
    output, = capture_io { Rake::Task["portfolio:verify_contract_coverage"].invoke }

    assert_match(/Verified \d+ portfolio contract rows against existing tests/, output)
  end

  test "contract coverage task aborts with the first problem found" do
    Portfolio::ContractCoverage.any_instance.stubs(:verify!).raises(Portfolio::ContractCoverage::Error, "P7: missing test \"gone\"")

    error = assert_raises(SystemExit) do
      capture_io { Rake::Task["portfolio:verify_contract_coverage"].invoke }
    end

    assert_not error.success?
  end
end
