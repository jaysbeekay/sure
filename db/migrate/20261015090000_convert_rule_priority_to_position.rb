# frozen_string_literal: true

# Fork only. The fork ordered rules by `priority` (20261001090000) and ran them
# in ascending `(priority, created_at, id)` order, each rule overwriting what
# the ones before it set, so the LAST rule in that order won. Upstream's
# 20261006140000 adds `position` instead, numbers existing rules A-Z by name,
# and runs them top to bottom with the FIRST (lowest position) rule winning.
# Both runners let a rule see what the rules before it wrote.
#
# Left at upstream's A-Z numbering, a family's rules could change outcome
# after the upgrade. This renumbers each family's rules so that, pair by pair:
#
# - A chain keeps the fork's order. When one rule writes a field another
#   rule's conditions read (a rename, then a rule matching the new name; or a
#   rule matching a name before a later rule renames it), the two run in the
#   order they ran on the fork, so each still sees what it saw.
# - A conflict is reversed. When two rules set the same field, the one that
#   ran last on the fork -- the one whose value stuck -- now runs first, where
#   it still wins.
# - Any other pair is reversed too, so a family with no chains gets the exact
#   reverse of the fork's order, as before.
#
# A pair that is both a chain and a conflict cannot keep both. The chain wins:
# reversed, the dependent rule would miss the rows the first one rewrote and
# lose every action it has on them, not just the contested field. Each such
# pair is reported in the migration output.
#
# The fork's order was total (created_at and id broke priority ties), so the
# result is too, and every family's positions come out as 1..n.
class ConvertRulePriorityToPosition < ActiveRecord::Migration[8.1]
  # The field each action writes, as a later condition would read it.
  # auto_categorize and auto_detect_merchants run in background jobs, after
  # the run, so no rule in the same run sees what they write.
  WRITES = {
    "set_transaction_name" => %w[name],
    "set_transaction_category" => %w[category],
    "set_transaction_merchant" => %w[merchant],
    "set_transaction_tags" => %w[tags],
    "set_as_transfer_or_payment" => %w[kind]
  }.freeze

  # The field each condition reads. "name" is the legacy alias of
  # transaction_name.
  READS = {
    "transaction_name" => "name",
    "name" => "name",
    "transaction_category" => "category",
    "transaction_merchant" => "merchant",
    "transaction_tag" => "tags",
    "transaction_type" => "kind"
  }.freeze

  # The fields upstream's runner lets only the first matching rule set
  # (Rule::ActionExecutor#claimed_attributes, for the executors that reserve
  # them). Tags are additive and claim nothing.
  CLAIMS = {
    "set_transaction_name" => %w[name],
    "set_transaction_category" => %w[category],
    "set_transaction_merchant" => %w[merchant],
    "exclude_transaction" => %w[excluded],
    "set_as_transfer_or_payment" => %w[transfer],
    "set_investment_activity_label" => %w[investment_activity_label]
  }.freeze

  def up
    return unless column_exists?(:rules, :priority)

    actions = select_rows("SELECT rule_id, action_type FROM rule_actions").group_by(&:first)
    reads = condition_types_by_rule.transform_values { |types| types.filter_map { |type| READS[type] }.to_set }

    families = select_rows(<<~SQL).group_by(&:last)
      SELECT id, family_id FROM rules ORDER BY family_id, priority, created_at, id
    SQL

    families.each_value do |rows|
      fork_order = rows.map(&:first)
      action_types = fork_order.map { |id| Array(actions[id]).map(&:last) }
      ranked = rank(
        fork_order,
        writes: action_types.map { |types| types.flat_map { |type| WRITES.fetch(type, []) }.to_set },
        reads: fork_order.map { |id| reads.fetch(id, Set.new) },
        claims: action_types.map { |types| types.flat_map { |type| CLAIMS.fetch(type, []) }.to_set }
      )
      write_positions(ranked)
    end

    remove_index :rules, [ :family_id, :priority ], if_exists: true
    remove_column :rules, :priority
  end

  # Restores the fork's column, ranked so that the top rule (which wins under
  # `position`) runs last again (where it won under `priority`). A chain that
  # `up` kept in the fork's order comes back reversed: `position` does not
  # record which pairs were chains.
  def down
    add_column :rules, :priority, :integer, null: false, default: 0

    execute <<~SQL
      UPDATE rules SET priority = ranked.rn
      FROM (
        SELECT id, ROW_NUMBER() OVER (
          PARTITION BY family_id ORDER BY position DESC, created_at DESC, id DESC
        ) AS rn
        FROM rules
      ) ranked
      WHERE rules.id = ranked.id
    SQL

    add_index :rules, [ :family_id, :priority ]
  end

  private
    # Condition types per rule id, with a compound's sub-conditions counted
    # under the rule their parent belongs to.
    def condition_types_by_rule
      rows = select_rows("SELECT id, rule_id, parent_id, condition_type FROM rule_conditions")
      rule_of = rows.to_h { |id, rule_id, _parent_id, _type| [ id, rule_id ] }

      rows.each_with_object(Hash.new { |hash, key| hash[key] = [] }) do |(_id, rule_id, parent_id, type), types|
        owner = rule_id || rule_of[parent_id]
        types[owner] << type if owner
      end
    end

    # The new order, top first. `before[a]` holds the rules `a` must run
    # before. Chain edges all point forward in the fork's order, so they never
    # form a cycle; a conflict edge is added only when it does not close one.
    # Among the rules free to go next, the one latest in the fork's order goes
    # first, which reverses every pair nothing else constrains.
    def rank(fork_order, writes:, reads:, claims:)
      count = fork_order.size
      before = Array.new(count) { Set.new }

      count.times do |i|
        (i + 1...count).each do |j|
          before[i] << j if writes[i].intersect?(reads[j]) || writes[j].intersect?(reads[i])
        end
      end

      (count - 1).downto(0) do |j|
        (0...j).each do |i|
          next unless claims[i].intersect?(claims[j])

          if reaches?(before, i, j)
            report_unkept_conflict(fork_order[i], fork_order[j])
          else
            before[j] << i
          end
        end
      end

      topological_order(before, count).map { |index| fork_order[index] }
    end

    def reaches?(before, from, to)
      seen = Set.new
      stack = [ from ]
      until stack.empty?
        node = stack.pop
        return true if node == to
        next unless seen.add?(node)

        stack.concat(before[node].to_a)
      end
      false
    end

    def topological_order(before, count)
      waiting = Array.new(count, 0)
      before.each { |successors| successors.each { |successor| waiting[successor] += 1 } }
      ready = (0...count).select { |index| waiting[index].zero? }
      order = []

      until ready.empty?
        index = ready.max
        ready.delete(index)
        order << index
        before[index].each do |successor|
          waiting[successor] -= 1
          ready << successor if waiting[successor].zero?
        end
      end

      order
    end

    def report_unkept_conflict(earlier_id, later_id)
      say "Rule #{earlier_id} now runs before rule #{later_id} to keep a chain between them; " \
          "both set the same field, so on rows both match the first rule's value now wins. " \
          "Reorder or edit them if the second rule's value should win."
    end

    def write_positions(ids)
      values = ids.each_with_index.map { |id, index| "(#{connection.quote(id)}::uuid, #{index + 1})" }.join(", ")
      execute <<~SQL
        UPDATE rules SET position = ranked.position
        FROM (VALUES #{values}) AS ranked(id, position)
        WHERE rules.id = ranked.id
      SQL
    end
end
