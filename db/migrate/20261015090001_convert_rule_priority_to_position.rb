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
# A pair that is both a chain and a conflict cannot keep both, and no order
# gives the same outcome as the fork. The migration then fails before writing
# anything and lists each such pair, so the owner can edit, disable or merge
# the rules and run it again. Only active rules can fail it: a rule that is
# not active takes no part in automatic runs, so its edges are kept where they
# fit and dropped where they would break a pair of active rules.
#
# The fork's order was total (created_at and id broke priority ties), so the
# result is too, and every family's positions come out as 1..n.
#
# Irreversible: `position` does not record which pairs were kept in the fork's
# order for a chain, so the fork's `priority` cannot be rebuilt from it.
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

    families = select_rows(<<~SQL).group_by { |row| row[1] }
      SELECT id, family_id, name, active FROM rules ORDER BY family_id, priority, created_at, id
    SQL

    unkept = []
    rankings = families.map do |family_id, rows|
      fork_order = rows.map(&:first)
      action_types = fork_order.map { |id| Array(actions[id]).map(&:last) }
      writes = action_types.map { |types| types.flat_map { |type| WRITES.fetch(type, []) }.to_set }
      claims = action_types.map { |types| types.flat_map { |type| CLAIMS.fetch(type, []) }.to_set }
      reads_by_index = fork_order.map { |id| reads.fetch(id, Set.new) }

      order, family_unkept = rank(
        writes: writes, reads: reads_by_index, claims: claims,
        active: rows.map { |row| ActiveModel::Type::Boolean.new.cast(row[3]) }
      )
      rule = ->(index) { { id: rows[index][0], name: rows[index][2] } }
      family_unkept.each do |earlier, later, chain|
        unkept << {
          family_id: family_id, earlier: rule.(earlier), later: rule.(later),
          fields: (claims[earlier] & claims[later]).to_a.sort,
          chain: chain.each_cons(2).map { |from, to| [ rule.(from), rule.(to), hop(from, to, writes, reads_by_index, claims) ] }
        }
      end
      order.map { |index| fork_order[index] }
    end

    raise ActiveRecord::MigrationError, unkept_conflicts_message(unkept) if unkept.any?

    rankings.each { |ids| write_positions(ids) }
    remove_index :rules, [ :family_id, :priority ], if_exists: true
    remove_column :rules, :priority
  end

  def down
    raise ActiveRecord::IrreversibleMigration, <<~MESSAGE
      The fork's rule order cannot be rebuilt from `rules.position`. `up` kept
      some pairs of rules in the fork's order (a chain) and reversed the rest,
      and `position` does not record which were which, so a rebuilt `priority`
      could run a chain backwards and change which rule wins. To go back,
      restore the database from a backup taken before this migration ran.
    MESSAGE
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

    # The new order, top first, as indices into the fork's order, and every
    # conflict between two active rules that a chain prevents from keeping its
    # winner, as [earlier, later, path from earlier to later].
    #
    # `before[a]` holds the rules `a` must run before. Chain edges point
    # forward in the fork's order and conflict edges backward. Edges between
    # active rules go in first: chains, which never form a cycle on their own,
    # then each conflict, unless it would close one. Edges touching a rule
    # that is not active go in after, wherever they fit. Among the rules free
    # to go next, the one latest in the fork's order goes first, which
    # reverses every pair nothing else constrains.
    def rank(writes:, reads:, claims:, active:)
      count = writes.size
      before = Array.new(count) { Set.new }
      unkept = []

      chains = []
      count.times do |i|
        (i + 1...count).each do |j|
          chains << [ i, j ] if writes[i].intersect?(reads[j]) || writes[j].intersect?(reads[i])
        end
      end

      conflicts = []
      (count - 1).downto(0) do |j|
        (0...j).each { |i| conflicts << [ j, i ] if claims[i].intersect?(claims[j]) }
      end

      both_active = ->(edge) { edge.all? { |index| active[index] } }

      chains.select(&both_active).each { |from, to| before[from] << to }
      conflicts.select(&both_active).each do |later, earlier|
        if (chain = path(before, earlier, later))
          unkept << [ earlier, later, chain ]
        else
          before[later] << earlier
        end
      end

      (chains + conflicts).reject(&both_active).each do |from, to|
        before[from] << to unless path(before, to, from)
      end

      [ topological_order(before, count), unkept ]
    end

    # The rules from `from` to `to` along `before`, both ends included, or nil.
    def path(before, from, to)
      came_from = { from => nil }
      queue = [ from ]
      until queue.empty?
        node = queue.shift
        if node == to
          route = [ node ]
          route.unshift(came_from[route.first]) while came_from[route.first]
          return route
        end

        before[node].sort.each do |successor|
          next if came_from.key?(successor)

          came_from[successor] = node
          queue << successor
        end
      end
      nil
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

    # Why `from` must run before `to`. Chain edges point forward in the fork's
    # order, conflict edges backward.
    def hop(from, to, writes, reads, claims)
      if from < to
        written = writes[from] & reads[to]
        return "#{describe_fields(written)}, written by the first and read by the second's conditions" if written.any?

        "#{describe_fields(reads[from] & writes[to])}, read by the first's conditions before the second rewrites it"
      else
        "#{describe_fields(claims[from] & claims[to])}, set by both; the first won on the fork"
      end
    end

    def describe_fields(fields)
      fields.to_a.sort.join(" and ")
    end

    def unkept_conflicts_message(unkept)
      describe = ->(rule) { %(rule #{rule[:id]} "#{rule[:name].presence || "(unnamed)"}") }

      pairs = unkept.group_by { |pair| pair[:family_id] }.map do |family_id, family_pairs|
        lines = family_pairs.map do |pair|
          chain = pair[:chain].map { |from, to, why| "      #{describe.(from)} -> #{describe.(to)}: #{why}" }
          <<~PAIR.chomp
            - #{describe.(pair[:earlier])} and #{describe.(pair[:later])} both set #{describe_fields(pair[:fields])}.
                On the fork the second ran last and its value won. To keep that, it would have to run
                first, but the first must run before it for this chain:
            #{chain.join("\n")}
          PAIR
        end
        "Family #{family_id}:\n#{lines.join("\n")}"
      end

      <<~MESSAGE
        Rule order conversion stopped: no order of these rules gives the same results as before.

        Each pair below sets the same field, and a chain (one rule's conditions reading what
        another writes) forces them into an order where the other rule's value would win.

        #{pairs.join("\n\n")}

        To fix: for each pair, edit one of the two rules so they no longer both set that field,
        disable one of them, or merge them into one rule. Then run `bin/rails db:migrate` again.
        The Docker image's web server will not start while this migration is pending; edit
        rules from `bin/rails console` instead, e.g. Rule.find("<id>").update!(active: false).

        Nothing was changed by this migration: `rules.priority` is still in place. `rules.position`
        holds the provisional A-Z order set by 20261006140000, which has already run. Until this
        migration succeeds, do not run rules: stop the background worker (Sidekiq), which would
        otherwise apply rules in that A-Z order during account syncs.
      MESSAGE
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
