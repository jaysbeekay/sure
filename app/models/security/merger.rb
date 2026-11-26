# Folds one security row into another that stands for the same instrument and
# deletes it, moving everything that references it: holdings, trades, lots,
# prices, splits, tags, classification proposals and constituents, and a
# classification a person asserted. Rows the target already has for the same
# key win, except holdings, where the most recently written row for an
# (account, date, currency) is kept. Accounts that referenced the merged row
# are synced afterwards so their holdings and balances are rebuilt on one row.
class Security::Merger
  # Who asserted a classification, by how far it outranks the rest: a person by
  # hand, then a person approving a proposal. Unlisted sources rank zero.
  PERSON_RANKS = { "ai" => 1, "manual" => 2 }.freeze

  def initialize(from:, into:)
    @from = from
    @into = into
  end

  # `condition` is checked against the locked source row, for callers whose
  # reason to merge could have changed since they last read it.
  def merge!(condition: nil)
    return into if from.id == into.id

    merged = nil
    account_ids = Security.transaction do
      # Security rows first, then (moving them) proposal rows: the order
      # Security::ClassificationProposal#approve! takes.
      locked = Security.where(id: [ from.id, into.id ]).order(:id).lock.to_a
      source = locked.find { |security| security.id == from.id }
      merged = target = locked.find { |security| security.id == into.id }
      # A concurrent merge already removed the row.
      next [] unless locked.size == 2
      next [] if condition && !condition.call(source)

      referencing_account_ids.tap do
        now = Time.current
        move_holdings!(now)
        Trade.where(security_id: from.id).update_all(security_id: into.id, updated_at: now)
        move_lots!(now)
        move_unless_target_has(Security::Price, :date, :currency)
        move_unless_target_has(Security::Split, :ex_date)
        move_taggings!
        move_proposals!
        update_target!(source, target, now)
        source.reload.destroy!
      end
    end

    Account.where(id: account_ids).find_each(&:sync_later)
    merged
  end

  private
    attr_reader :from, :into

    def referencing_account_ids
      trade_entries = Entry.where(entryable_type: "Trade", entryable_id: Trade.where(security_id: from.id).select(:id))
      lots = HoldingLot.where(security_id: from.id).or(HoldingLot.where(origin_security_id: from.id))
      holdings = Holding.where(security_id: from.id).or(Holding.where(provider_security_id: from.id))

      [ holdings, trade_entries, lots ].flat_map { |scope| scope.distinct.pluck(:account_id) }.uniq
    end

    def move_holdings!(now)
      collisions = Holding.where(security_id: from.id)
        .joins(Holding.sanitize_sql_array([ <<~SQL, into.id ]))
          INNER JOIN holdings kept ON kept.security_id = ?
            AND kept.account_id = holdings.account_id
            AND kept.date = holdings.date
            AND kept.currency = holdings.currency
        SQL
        .pluck("holdings.id", "holdings.updated_at", "kept.id", "kept.updated_at")

      stale_ids = collisions.map { |id, updated_at, kept_id, kept_updated_at| updated_at > kept_updated_at ? kept_id : id }
      Holding.where(id: stale_ids).delete_all

      Holding.where(security_id: from.id).update_all(security_id: into.id, updated_at: now)
      Holding.where(provider_security_id: from.id).update_all(provider_security_id: into.id, updated_at: now)
      # A holding remapped away from a provider security that is now the
      # security it points to is no longer remapped.
      Holding.where(security_id: into.id, provider_security_id: into.id)
        .update_all(provider_security_id: nil, security_locked: false, updated_at: now)
    end

    def move_lots!(now)
      lots = HoldingLot.where(security_id: from.id)
      HoldingLot.move!(derived: lots.derived, opening: lots.opening, to: into)
      HoldingLot.where(origin_security_id: from.id).update_all(origin_security_id: into.id, updated_at: now)
    end

    # One write, without validations: a target invalid for an unrelated reason
    # (a price provider since removed) must not roll the merge back.
    def update_target!(source, target, now)
      attributes = {}
      attributes[:name] = source.name if target.name.blank? && source.name.present?
      attributes.merge!(classification_from(source, target))
      attributes.merge!(move_constituents!(source, target, now))
      target.update_columns(attributes.merge(updated_at: now)) if attributes.any?
    end

    # A classification a person asserted survives the merge when it outranks
    # the target's and the target is not locked. As with
    # Security::ClassificationProposal#source_attributes, an answer without an
    # asset class claims nothing: copied locked it would shut the provider out
    # of the asset class, copied unlocked it would be open to overwriting, so
    # the provider classifies the target instead.
    def classification_from(source, target)
      return {} if source.asset_class.blank? || target.classification_locked?
      return {} unless PERSON_RANKS.fetch(source.classification_source, 0) > PERSON_RANKS.fetch(target.classification_source, 0)

      { sector: source.sector, industry: source.industry, region: source.region }.compact_blank.merge(
        asset_class: source.asset_class,
        asset_sub_class: source.asset_sub_class.presence,
        classification_source: source.classification_source,
        classification_locked: source.classification_locked
      )
    end

    # One proposal per family survives: the pending one when only one of the
    # two is pending, otherwise the target's.
    def move_proposals!
      proposals = Security::ClassificationProposal
      pending_on_source = proposals.pending.where(security_id: from.id).select(:family_id)
      proposals.where(security_id: into.id, family_id: pending_on_source).where.not(status: "pending").delete_all
      move_unless_target_has(proposals, :family_id)
    end

    # A target the provider has already answered, with rows or an empty list,
    # keeps its answer; the source's rows go with the source. Otherwise the
    # target takes the source's answer, an empty one included, so the provider
    # is not asked again.
    def move_constituents!(source, target, now)
      return {} if target.constituents_fetched_at.present? || Security::Constituent.exists?(security_id: target.id)

      Security::Constituent.where(security_id: source.id).update_all(security_id: target.id, updated_at: now)
      source.constituents_fetched_at ? { constituents_fetched_at: source.constituents_fetched_at } : {}
    end

    def move_unless_target_has(model, *key_columns)
      table = model.arel_table
      kept = table.alias("kept")
      same_key = key_columns.map { |column| kept[column].eq(table[column]) }.reduce(:and)
      kept_row = Arel::SelectManager.new.from(kept).project(Arel.sql("1")).where(kept[:security_id].eq(into.id).and(same_key))

      rows = model.where(security_id: from.id)
      rows.where(kept_row.exists).delete_all
      rows.update_all(security_id: into.id, updated_at: Time.current)
    end

    def move_taggings!
      taggings = Tagging.where(taggable_type: "Security", taggable_id: from.id)
      taggings.where(tag_id: Tagging.where(taggable_type: "Security", taggable_id: into.id).select(:tag_id)).delete_all
      taggings.update_all(taggable_id: into.id, updated_at: Time.current)
    end
end
