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

  test "a failing new generator is logged and skipped, and the others still run" do
    # Only the registry's contract is under test, so every other generator is
    # inert: none of them can raise, log or add a type as fixtures age.
    (Insight::GeneratorRegistry::GENERATORS - [ Insight::Generators::SpendingPaceGenerator, Insight::Generators::BudgetInsightGenerator ]).each do |generator|
      generator.any_instance.stubs(:generate).returns([])
    end
    Insight::Generators::SpendingPaceGenerator.any_instance.stubs(:generate).raises(StandardError, "boom")
    survivor = Insight::Generator::GeneratedInsight.new(
      insight_type: "budget_on_track", priority: "low", title: "t", template_key: "budget_on_track", facts: {}, metadata: {},
      currency: "USD", period_start: nil, period_end: nil, dedup_key: "budget_on_track:test"
    )
    Insight::Generators::BudgetInsightGenerator.any_instance.stubs(:generate).returns([ survivor ])

    result = nil
    assert_difference "DebugLogEntry.count", 1 do
      result = Insight::GeneratorRegistry.new(@family).generate_all
    end

    assert_equal [ survivor ], result.insights
    assert_not_includes result.succeeded_types, "spending_pace"
    assert_includes result.succeeded_types, "budget_on_track"
  end
end
