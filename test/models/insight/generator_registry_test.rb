require "test_helper"

class Insight::GeneratorRegistryTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
  end

  # Every type a registered generator can produce must be a valid Insight type,
  # or the job's create! would raise for it in production.
  test "every produced type is a valid insight type" do
    produced = Insight::GeneratorRegistry::GENERATORS.flat_map(&:produced_types)

    assert_empty produced - Insight::TYPES
  end

  # The failure sits mid-registry, with a survivor on each side of it, so a
  # registry that stopped at the first failure would lose the one after it.
  test "a failing generator is logged and skipped, and the ones before and after it still run" do
    before = Insight::Generators::SpendingAnomalyGenerator
    failing = Insight::Generators::BudgetInsightGenerator
    after = Insight::Generators::SpendingPaceGenerator
    generators = Insight::GeneratorRegistry::GENERATORS
    assert generators.index(before) < generators.index(failing), "the first survivor must run before the failure"
    assert generators.index(failing) < generators.index(after), "the second survivor must run after the failure"

    # Only the registry's contract is under test, so every other generator is
    # inert: none of them can raise, log or add a type as fixtures age.
    (generators - [ before, failing, after ]).each do |generator|
      generator.any_instance.stubs(:generate).returns([])
    end
    failing.any_instance.stubs(:generate).raises(StandardError, "boom")
    first = generated("spending_anomaly")
    last = generated("spending_pace")
    before.any_instance.stubs(:generate).returns([ first ])
    after.any_instance.stubs(:generate).returns([ last ])

    result = nil
    assert_difference "DebugLogEntry.count", 1 do
      result = Insight::GeneratorRegistry.new(@family).generate_all
    end

    assert_equal [ first, last ], result.insights
    assert_includes result.succeeded_types, "spending_anomaly"
    assert_includes result.succeeded_types, "spending_pace"
    assert_empty failing.produced_types & result.succeeded_types
  end

  private
    def generated(type)
      Insight::Generator::GeneratedInsight.new(
        insight_type: type, priority: "low", title: "t", template_key: type, facts: {}, metadata: {},
        currency: "USD", period_start: nil, period_end: nil, dedup_key: "#{type}:test"
      )
    end
end
