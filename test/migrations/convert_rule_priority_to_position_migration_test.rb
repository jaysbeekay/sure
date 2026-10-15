# frozen_string_literal: true

require "test_helper"
require Rails.root.join("db/migrate/20261015090000_convert_rule_priority_to_position")

# Fork only. The schema this test runs on has already been migrated, so the
# fork's `priority` column is put back by hand to rebuild the state an existing
# fork database is in when this migration runs: `priority` set the way the fork
# set it, and `position` numbered A-Z by name, as upstream's 20261006140000
# leaves it. DDL is transactional in PostgreSQL, so each test's schema change
# rolls back with the test.
class ConvertRulePriorityToPositionMigrationTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    connection.add_column :rules, :priority, :integer, null: false, default: 0
    connection.add_index :rules, [ :family_id, :priority ]
    Rule.reset_column_information

    @family = families(:empty)
    @account = @family.accounts.create!(name: "Rules", balance: 1000, currency: "USD", accountable: Depository.new)
    @groceries = @family.categories.create!(name: "Groceries")
    @dining = @family.categories.create!(name: "Dining")
    @entry = create_transaction(date: Date.current, account: @account, name: "Whole Foods Market")
  end

  teardown do
    Rule.reset_column_information
  end

  # The fork ran rules in ascending priority and the LAST one's value stuck.
  # Upstream runs them by position and the FIRST one's value sticks. The two
  # rules below both set the category of the same transaction. Named so that
  # upstream's A-Z numbering puts the fork's loser on top: without this
  # migration the upgrade would flip the outcome, which the first half shows.
  test "a family's conflicting rules give the same category before and after" do
    loser = rule_setting(@dining, name: "Alpha", priority: 1)
    winner = rule_setting(@groceries, name: "Zulu", priority: 2)
    number_by_name_as_upstream_does

    before = category_under_fork_order
    assert_equal @groceries, before, "precondition: under the fork the later rule, Zulu, wins"

    reset_category
    ApplyAllRulesJob.perform_now(@family)
    assert_equal @dining, category_of(@entry),
                 "precondition: left at upstream's A-Z numbering, the upgrade flips the outcome"

    migrate(:up)
    reset_category
    ApplyAllRulesJob.perform_now(@family)

    assert_equal before, category_of(@entry)
    assert_equal [ winner.id, loser.id ], @family.rules.ordered.pluck(:id)
  end

  # The mapping is the exact reverse of the fork's total order (priority, then
  # created_at, then id), per family, so ties fall the way the fork broke them.
  # Each key is exercised: dropping or flipping any one of them moves a rule.
  test "positions are the fork's run order reversed, per family" do
    first, twins, elder, younger = rules_with_every_tie
    other_family = families(:dylan_family)
    other_family.rules.destroy_all
    other_a = other_family.rules.create!(resource_type: "transaction", name: "a", actions: [ Rule::Action.new(action_type: "exclude_transaction") ])
    other_b = other_family.rules.create!(resource_type: "transaction", name: "b", actions: [ Rule::Action.new(action_type: "exclude_transaction") ])
    other_a.update_columns(priority: 1)
    other_b.update_columns(priority: 2)

    fork_order = Rule.where(family: @family).order(:priority, :created_at, :id).pluck(:id)
    assert_equal [ first, *twins, elder, younger ].map(&:id), fork_order, "precondition: the fork's order"

    migrate(:up)

    assert_equal fork_order.reverse, @family.rules.ordered.pluck(:id)
    assert_equal({ younger.id => 1, elder.id => 2, twins.last.id => 3, twins.first.id => 4, first.id => 5 },
                 Rule.where(family: @family).pluck(:id, :position).to_h)
    assert_equal({ other_b.id => 1, other_a.id => 2 }, Rule.where(family: other_family).pluck(:id, :position).to_h)
    assert_not connection.column_exists?(:rules, :priority)
    assert_not connection.index_exists?(:rules, [ :family_id, :priority ])
  end

  test "down restores priority in the fork's order, so the same rule wins again" do
    first, twins, elder, younger = rules_with_every_tie

    migrate(:up)
    migrate(:down)

    assert_equal({ first.id => 1, twins.first.id => 2, twins.last.id => 3, elder.id => 4, younger.id => 5 },
                 connection.select_rows("SELECT id, priority FROM rules WHERE family_id = '#{@family.id}'").to_h)
    assert connection.index_exists?(:rules, [ :family_id, :priority ])
  end

  private
    def connection
      ActiveRecord::Base.connection
    end

    def migrate(direction)
      ActiveRecord::Migration.suppress_messages { ConvertRulePriorityToPosition.new.migrate(direction) }
      Rule.reset_column_information
    end

    def rule_setting(category, name:, priority:, created_at: nil)
      rule = @family.rules.create!(
        resource_type: "transaction", name: name, active: true,
        conditions: [ Rule::Condition.new(condition_type: "transaction_name", operator: "like", value: "whole foods") ],
        actions: [ Rule::Action.new(action_type: "set_transaction_category", value: category.id) ]
      )
      rule.update_columns(priority: priority)
      rule.update_columns(created_at: created_at) if created_at
      rule
    end

    # Five rules whose fork order needs every key. Priority puts `first` before
    # the twins before the pair. The twins share a priority AND a created_at,
    # so only the id separates them. The pair share a priority, and the elder
    # is given the larger id, so created_at and id disagree about them.
    # Returns [first, twins sorted by id, elder, younger].
    def rules_with_every_tie
      instant = 3.days.ago
      first = rule_setting(@dining, name: "first", priority: 1, created_at: 4.days.ago)
      twin_a = rule_setting(@dining, name: "twin a", priority: 2, created_at: instant)
      twin_b = rule_setting(@dining, name: "twin b", priority: 2, created_at: instant)
      younger, elder = [ rule_setting(@dining, name: "pair", priority: 3), rule_setting(@dining, name: "pair", priority: 3) ].sort_by(&:id)
      elder.update_columns(created_at: 6.days.ago)
      younger.update_columns(created_at: 5.days.ago)

      [ first, [ twin_a, twin_b ].sort_by(&:id), elder, younger ]
    end

    # What 20261006140000 does to a fork database's existing rules.
    def number_by_name_as_upstream_does
      connection.execute(<<~SQL)
        UPDATE rules SET position = ranked.rn
        FROM (
          SELECT id, ROW_NUMBER() OVER (PARTITION BY family_id ORDER BY LOWER(name) NULLS LAST, created_at, id) AS rn
          FROM rules
        ) ranked
        WHERE rules.id = ranked.id
      SQL
    end

    # The fork's ApplyAllRulesJob: every rule in ascending priority, each one
    # overwriting what the ones before it set (Rule.apply_in_priority_order ran
    # RuleJob, which ran Rule#apply with no claims).
    def category_under_fork_order
      reset_category
      @family.rules.order(:priority, :created_at, :id).each { |rule| rule.apply(ignore_attribute_locks: true) }
      category_of(@entry)
    end

    def reset_category
      @entry.transaction.update_columns(category_id: nil, locked_attributes: {})
    end

    def category_of(entry)
      entry.reload.transaction.reload.category
    end
end
