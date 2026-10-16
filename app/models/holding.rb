class Holding < ApplicationRecord
  include Monetizable, Gapfillable

  monetize :amount

  # Cost basis source priority (higher = takes precedence)
  COST_BASIS_SOURCE_PRIORITY = {
    nil => 0,
    "provider" => 1,
    "calculated" => 2,
    "manual" => 3
  }.freeze

  COST_BASIS_SOURCES = %w[manual calculated provider].freeze

  belongs_to :account
  belongs_to :security
  belongs_to :account_provider, optional: true
  belongs_to :provider_security, class_name: "Security", optional: true

  validates :qty, :currency, :date, :price, :amount, presence: true
  validates :qty, :price, :amount, numericality: { greater_than_or_equal_to: 0 }
  validates :external_id, uniqueness: { scope: :account_id }, allow_blank: true
  validates :cost_basis_source, inclusion: { in: COST_BASIS_SOURCES }, allow_nil: true

  scope :chronological, -> { order(:date) }
  scope :for, ->(security) { where(security_id: security).order(:date) }
  scope :with_locked_cost_basis, -> { where(cost_basis_locked: true) }
  scope :with_unlocked_cost_basis, -> { where(cost_basis_locked: false) }

  delegate :ticker, to: :security

  def name
    security.name || ticker
  end

  def weight
    return nil unless amount
    return 0 if amount.zero?

    account.balance.zero? ? 1 : amount_in_account_currency / account.balance * 100
  end

  # Returns average cost per share, or nil if unknown.
  #
  # Uses pre-computed cost_basis if available (set during materialization),
  # otherwise falls back to calculating from trades. Returns nil when cost
  # basis cannot be determined (no trades and no provider cost_basis).
  def avg_cost
    stored = stored_avg_cost
    return stored if stored

    # A caller that has many holdings can compute the fallback for all of
    # them in one query and hand each its answer (InvestmentStatement does),
    # so a page that lists every position does not run calculate_avg_cost's
    # two queries per holding. nil is a valid preloaded answer: "unknown".
    return @preloaded_avg_cost if defined?(@preloaded_avg_cost)

    # Fallback to calculation for holdings without pre-computed cost_basis
    calculate_avg_cost
  end

  # The stored cost_basis as average cost per share, or nil when there is none
  # to trust. Never queries, so a caller with a better fallback than replaying
  # through this holding's date (Trade#realized_gain_loss) can skip that replay.
  #
  # - If locked (user-set), trust the value even if 0 (valid for airdrops)
  # - Otherwise require positive since providers sometimes return 0 when unknown
  def stored_avg_cost
    return nil if cost_basis.nil?

    Money.new(cost_basis, currency) if cost_basis_locked? || cost_basis.positive?
  end

  # The weighted-average cost of the position immediately before `entry`,
  # replayed from this security's trades as calculate_avg_cost does, or nil
  # when it is unknown. Realized gain prices a sale at this figure: average
  # cost does not move on a sale, but a sale that closes the position leaves
  # a row with nothing held and no basis, so `avg_cost` has no figure to give.
  #
  # Trades count when they sort strictly before `entry` in Entry.chronological
  # order, so a buy earlier the same day counts and the sale itself does not.
  # A split with an ex-date on or before the sale's date counts, since a split
  # applies at the open of its ex-date.
  def avg_cost_before(entry)
    calculate_avg_cost(through: entry.date, before: entry)
  end

  # The rule Holding#avg_cost applies to a stored basis before it falls
  # back to trades: locked values are trusted even at zero, unlocked ones
  # only when positive.
  def self.stored_cost_basis?(holding)
    holding.cost_basis.present? && (holding.cost_basis_locked? || holding.cost_basis.positive?)
  end

  # One query for the fallback Holding#calculate_avg_cost would run per
  # holding: the weighted average of buy trades on or before the holding's
  # date, converted to the account currency at each trade's date, unknown
  # (nil) when any of those trades is a Transfer or when there are none.
  # The SQL mirrors #calculate_avg_cost line for line; the parity test in
  # InvestmentStatementTest holds them together.
  def self.preload_avg_costs(holdings)
    pending = holdings.reject { |holding| stored_cost_basis?(holding) }
    return if pending.empty?

    rows = ActiveRecord::Base.connection.select_all(
      ActiveRecord::Base.sanitize_sql_array([
        <<~SQL.squish,
          SELECT cur.id AS holding_id,
            BOOL_OR(trades.investment_activity_label = :transfer_label) AS has_transfer,
            SUM(CASE WHEN trades.investment_activity_label IS DISTINCT FROM :transfer_label
              THEN trades.price * trades.qty * COALESCE(exchange_rates.rate, 1) ELSE 0 END) AS total_cost,
            SUM(CASE WHEN trades.investment_activity_label IS DISTINCT FROM :transfer_label
              THEN trades.qty ELSE 0 END) AS total_qty
          FROM holdings cur
          JOIN accounts ON accounts.id = cur.account_id
          JOIN entries ON entries.account_id = cur.account_id
            AND entries.entryable_type = 'Trade'
            AND entries.date <= cur.date
          JOIN trades ON trades.id = entries.entryable_id
            AND trades.security_id = cur.security_id
            AND trades.qty > 0
          LEFT JOIN exchange_rates ON (
            exchange_rates.date = entries.date
            AND exchange_rates.from_currency = trades.currency
            AND exchange_rates.to_currency = accounts.currency
          )
          WHERE cur.id IN (:holding_ids)
          GROUP BY cur.id
        SQL
        { holding_ids: pending.map(&:id), transfer_label: Trade::TRANSFER_LABEL }
      ])
    ).index_by { |row| row["holding_id"] }

    pending.each do |holding|
      row = rows[holding.id]
      total_qty = row && row["total_qty"]&.to_d
      value = if row.nil? || row["has_transfer"] || total_qty.nil? || total_qty <= 0
        nil
      else
        Money.new(row["total_cost"].to_d / total_qty, holding.currency)
      end
      holding.preload_avg_cost(value)
    end
  end
  private_class_method :stored_cost_basis?

  def preload_avg_cost(value)
    @preloaded_avg_cost = value
  end

  # A reload replaces the attributes, so an answer computed from the old ones
  # must go with them -- including #trend, which is derived from avg_cost.
  # Without this a caller that preloads, reloads and reads would get the
  # pre-reload cost basis back.
  def reload(*)
    remove_instance_variable(:@preloaded_avg_cost) if defined?(@preloaded_avg_cost)
    remove_instance_variable(:@trend) if defined?(@trend)
    remove_instance_variable(:@day_change) if defined?(@day_change)
    super
  end

  def trend
    @trend ||= calculate_trend
  end

  # Day change based on previous holding snapshot (same account/security/currency)
  # Returns a Trend struct similar to other trend usages or nil if no prior snapshot.
  def day_change
    # Memoize even when nil to avoid repeated queries during a request lifecycle
    return @day_change if instance_variable_defined?(:@day_change)

    return (@day_change = nil) unless amount_money

    prev = account.holdings
                 .where(security_id: security_id, currency: currency)
                 .where("date < ?", date)
                 .order(date: :desc)
                 .first

    @day_change = prev&.amount_money ? Trend.new(current: amount_money, previous: prev.amount_money) : nil
  end

  def trades
    account.entries.where(entryable: account.trades.where(security: security)).reverse_chronological
  end

  def destroy_holding_and_entries!
    transaction do
      account.entries.where(entryable: account.trades.where(security: security)).destroy_all
      destroy
    end

    account.sync_later
  end

  # Returns the priority level for the current source (higher = better)
  def cost_basis_source_priority
    COST_BASIS_SOURCE_PRIORITY[cost_basis_source] || 0
  end

  # Check if this holding's cost_basis can be overwritten by the given source
  def cost_basis_replaceable_by?(new_source)
    return false if cost_basis_locked?

    new_priority = COST_BASIS_SOURCE_PRIORITY[new_source] || 0

    # Special case: when user unlocks a manual cost_basis, they're opting into
    # recalculation. Allow only "calculated" source to replace it (from trades).
    # This is the whole point of the unlock action.
    if cost_basis_source == "manual"
      return new_source == "calculated"
    end

    # Allow refreshes from the same source (e.g., new trades change calculated cost basis,
    # or providers send updated cost basis).
    new_priority >= cost_basis_source_priority
  end

  # Set cost_basis from user input (locks the value)
  def set_manual_cost_basis!(value)
    update!(
      cost_basis: value,
      cost_basis_source: "manual",
      cost_basis_locked: true
    )
  end

  # Unlock cost_basis to allow provider/calculated updates
  def unlock_cost_basis!
    update!(cost_basis_locked: false)
  end

  # Check if this holding's security can be changed by provider sync
  def security_replaceable_by_provider?
    !security_locked?
  end

  # Check if user has remapped this holding to a different security
  # Also verifies the provider_security record still exists (FK should prevent deletion, but be safe)
  def security_remapped?
    provider_security_id.present? && security_id != provider_security_id && provider_security.present?
  end

  # Remap this holding (and all other holdings for the same security) to a different security
  # Also moves all trades for the old security to the new security
  # If the target security already has holdings on some dates, merge by combining qty/amount
  def remap_security!(new_security)
    return if new_security.id == security_id

    old_security = security

    transaction do
      # Find (date, currency) pairs where the new security already has holdings (collision keys)
      # Currency must match to merge - can't combine holdings denominated in different currencies
      collision_keys = account.holdings
        .where(security: new_security)
        .where(date: account.holdings.where(security: old_security).select(:date))
        .pluck(:date, :currency)
        .to_set

      # Process each holding for the old security
      account.holdings.where(security: old_security).find_each do |holding|
        if collision_keys.include?([ holding.date, holding.currency ])
          # Collision: merge into existing holding for new_security (same date AND currency)
          existing = account.holdings.find_by!(security: new_security, date: holding.date, currency: holding.currency)
          merged_qty = existing.qty + holding.qty
          merged_amount = existing.amount + holding.amount

          # Calculate weighted average cost basis if both holdings have cost_basis
          merged_cost_basis = if existing.cost_basis.present? && holding.cost_basis.present? && merged_qty.positive?
            ((existing.cost_basis * existing.qty) + (holding.cost_basis * holding.qty)) / merged_qty
          else
            existing.cost_basis # Keep existing if we can't calculate weighted average
          end

          # Preserve provider tracking from the holding being destroyed
          # so subsequent syncs can find the merged holding
          merge_attrs = {
            qty: merged_qty,
            amount: merged_amount,
            price: merged_qty.positive? ? merged_amount / merged_qty : 0,
            cost_basis: merged_cost_basis
          }
          merge_attrs[:external_id] ||= holding.external_id if existing.external_id.blank? && holding.external_id.present?
          merge_attrs[:provider_security_id] ||= holding.provider_security_id || old_security.id if existing.provider_security_id.blank?
          merge_attrs[:account_provider_id] ||= holding.account_provider_id if existing.account_provider_id.blank? && holding.account_provider_id.present?
          merge_attrs[:security_locked] = true # Lock merged holding to prevent provider overwrites

          # Merge the moved row into the existing one, then delete the moved
          # row so the (account, security, date, currency) unique pair stays
          # single. The merge keeps the existing row and absorbs qty/amount
          # from the moved row; destroying the moved row (never the existing)
          # also satisfies the DB unique constraint on that pair.
          #
          # Bypass validations (QA note #3): the merged qty/amount may be
          # negative — that is exactly the case #301 is about (a +22 row on one
          # record and a -22 row on another merging to a row the >=0 check
          # would reject). It is a derived value the materializer recomputes,
          # so validate-and-reject is the wrong tool here. update_columns
          # also writes only the columns listed, so a merged amount is never
          # validated. The original save!/update! raised RecordInvalid on
          # exactly this and rolled the whole remap back.
          #
          # update_columns does not touch updated_at, and cached investment
          # series key on the newest holdings.updated_at
          # (InvestmentStatement#holdings_version), so it is set here.
          existing.update_columns(merge_attrs.merge(updated_at: Time.current))
          holding.destroy!
        else
          # No collision: update to new security.
          #
          # Write only the columns this remap owns, bypassing validations
          # (QA note #3). Holdings are derived rows the materializer rebuilds:
          # straight after this the controller re-materializes on the new
          # security and the forward calculator regenerates qty/amount/price.
          # The >=0 validations on qty/amount exist to stop a *user* from typing
          # a negative value into an ordinary edit — they must not veto moving a
          # computed derived row that legitimately carries a negative qty/amount
          # (e.g. a full in-kind transfer out). Using save! here raised
          # RecordInvalid on exactly that case and silently rolled the whole
          # remap back — #301.
          holding.update_columns(
            security_id: new_security.id,
            security_locked: true,
            provider_security_id: holding.provider_security_id || old_security.id,
            updated_at: Time.current
          )
        end
      end

      # Move all trades for old security to new security
      account.trades.where(security: old_security).update_all(security_id: new_security.id)
    end

    # Reload self to reflect changes (may raise RecordNotFound if self was destroyed)
    begin
      reload
    rescue ActiveRecord::RecordNotFound
      nil
    end
  end

  # Reset security (and all related holdings) back to what the provider originally sent
  # Note: This moves ALL trades for current_security back to original_security. If the user
  # had legitimate trades for the target security before remapping, those would also be moved.
  # In practice this is rare since SimpleFIN doesn't provide trades, and Plaid trades would
  # typically be for real tickers not CUSTOM: ones. A more robust solution would track which
  # trades were moved during remap, but that adds significant complexity for an edge case.
  def reset_security_to_provider!
    return unless provider_security_id.present?

    current_security = security
    original_security = provider_security

    # Guard against deleted provider_security (shouldn't happen due to FK, but be safe)
    return unless original_security.present?

    transaction do
      # Move trades back (see note above about limitation)
      account.trades.where(security: current_security).update_all(security_id: original_security.id)

      # Reset ALL holdings that were remapped from this provider_security
      # (QA note #3): write only the columns this reset owns, bypassing
      # validations. Same rationale as remap_security! — these are derived
      # rows the materializer rebuilds, and a negative qty/amount must not
      # stop them moving back to the provider's original security. The
      # original holding.update! raised RecordInvalid on exactly that and
      # rolled the whole reset back.
      account.holdings.where(security: current_security, provider_security: original_security).find_each do |holding|
        holding.update_columns(
          security_id: original_security.id,
          security_locked: false,
          provider_security_id: nil,
          updated_at: Time.current
        )
      end
    end

    # Reload self to reflect changes
    reload
  end

  # Check if cost_basis is known (has a source and positive value)
  def cost_basis_known?
    cost_basis.present? && cost_basis.positive? && cost_basis_source.present?
  end

  # Human-readable source label for UI display
  def cost_basis_source_label
    return nil unless cost_basis_source.present?

    I18n.t("holdings.cost_basis_sources.#{cost_basis_source}")
  end

  private
    def amount_in_account_currency
      return amount if currency == account.currency

      Money.new(amount, currency).exchange_to(account.currency, date: date).amount
    rescue Money::ConversionError
      amount
    end

    def calculate_trend
      return nil unless amount_money
      return nil if avg_cost.nil? # Can't calculate trend without cost basis (0 is valid for airdrops)

      start_amount = qty * avg_cost

      Trend.new \
        current: amount_money,
        previous: start_amount
    end

    # The weighted-average cost of the position on this holding's date, worked
    # out from the trades the way the holding calculators work it out
    # (Holding::ForwardCalculator#apply_trades), so a holding with no stored
    # basis shows the figure the next materialization would store: sells are
    # relieved at the running average, a split rescales the position at the
    # open of its ex-date, and a transfer in makes the cost unknown until the
    # position is closed. Returns nil when the cost is unknown.
    #
    # `through` is the last day replayed, the holding's own date by default.
    # `before`, an entry on that day, stops the replay just short of it
    # (avg_cost_before).
    #
    # The replay starts from the position the trades do not explain, as
    # Holding::ReverseCalculator#precompute_cost_basis seeds it from the
    # provider's snapshot: a reverse-synced account can hold shares from
    # before its first imported trade, and a sale that empties the imported
    # trades then leaves those still held, so a transfer among them stays
    # unknown. This holding's quantity, walked back through the trades and
    # splits up to its date, is that opening position; for a forward-synced
    # or manual account it is zero.
    def calculate_avg_cost(through: date, before: nil)
      tracker = Holding::CostBasisTracker.new
      transferred = false
      all_splits = Security::Split.where(security_id: security_id, ex_date: ..[ through, date ].max).order(:ex_date).to_a
      rows = avg_cost_trade_rows(through: through, before: before)
      position = opening_position(rows, all_splits)
      splits = all_splits.select { |split| split.ex_date <= through }

      apply_splits = lambda do |through|
        while splits.any? && splits.first.ex_date <= through
          ratio = splits.shift.ratio
          tracker.split(ratio)
          position = Security::Split.scale(position, ratio)
        end
      end

      rows.each do |trade_date, qty, unit_cost, internal_movement, replayed|
        break unless replayed

        apply_splits.call(trade_date)
        previous_position = position

        # Units moved in were acquired at a price nothing here knows -- a coin
        # bought at 30k and moved in at 60k would report no gain -- so they
        # make the whole position's cost unknown. Units moved out are relieved
        # at the running average, like a sell.
        if internal_movement && qty.positive?
          transferred = true
        else
          tracker.apply(unit_cost, qty)
        end

        position += qty
        # Only a genuine downward crossing through zero clears the mark, as in
        # the calculators: a position that was never positive held no units.
        transferred = false if previous_position.positive? && position <= 0
      end
      apply_splits.call(through)

      return nil if transferred

      # Rounded to the scale `cost_basis` is stored at, so the figure is the one
      # the next materialization writes, not one a per-unit fee leaves at
      # 214.99999... when the stored basis reads 215.
      average = tracker.average_cost
      Money.new(average.round(self.class.columns_hash["cost_basis"].scale), currency) if average
    end

    # The position held before the first of `rows`: this holding's quantity
    # with every trade and split up to its date undone, latest first. A split
    # applies at the open of its ex-date, so it is undone after that day's
    # trades.
    def opening_position(rows, splits)
      position = qty.to_d
      pending = splits.select { |split| split.ex_date <= date }

      rows.reverse_each do |trade_date, trade_qty|
        next if trade_date > date

        position = Security::Split.unscale(position, pending.pop.ratio) while pending.any? && pending.last.ex_date > trade_date
        position -= trade_qty
      end
      pending.reverse_each { |split| position = Security::Split.unscale(position, split.ratio) }

      position
    end

    # This security's trades up to this holding's date and up to the replay's
    # cutoff -- `through`, or strictly before the entry `before` in the same
    # order -- oldest first in Entry.chronological order, as
    # [date, qty, unit cost, internal movement?, replayed?]. Both sets are a
    # prefix of that order, so the replayed rows lead and one query serves the
    # walk back to the opening position and the replay.
    # Unit cost is in the account's currency and includes the fee on a
    # purchase (Holding::TradeCalculatorHelpers#effective_trade_price); it is
    # nil when a foreign trade has no usable rate for its day, which the
    # tracker treats as an unknown cost until the position closes.
    def avg_cost_trade_rows(through:, before:)
      # The rate a trade carries itself (extra["exchange_rate"], e.g. IBKR's
      # fx_rate_to_base) comes before the table's, as in the calculators and
      # Balance::SyncCache; a trade in the account's own currency converts at 1.
      # Trade#exchange_rate= stores a number, but a row written to `extra`
      # directly can hold the same rate as a string, which Trade's validation
      # and Money#exchange_to both accept -- so a plain decimal string counts
      # too. Anything else, an exponent or an absurd length included, is not
      # cast, so it cannot overflow numeric and fail the query. A rate of zero
      # or less converts nothing, so it counts as missing, as it does in
      # Money#exchange_to.
      rate = <<~SQL.squish
        COALESCE(
          CASE jsonb_typeof(trades.extra->'exchange_rate')
            WHEN 'number' THEN (trades.extra->>'exchange_rate')::numeric
            WHEN 'string' THEN CASE WHEN trades.extra->>'exchange_rate' ~ '^[[:space:]]*[+-]?([0-9]{1,20}([.][0-9]{0,20})?|[.][0-9]{1,20})[[:space:]]*$'
                                    THEN (trades.extra->>'exchange_rate')::numeric END
          END,
          exchange_rates.rate
        )
      SQL
      foreign = ActiveRecord::Base.sanitize_sql_array([ "trades.currency <> ?", account.currency ])
      factor = "CASE WHEN #{foreign} THEN CASE WHEN #{rate} > 0 THEN #{rate} END ELSE 1 END"
      unit_cost = "CASE WHEN trades.qty > 0 THEN (trades.price + COALESCE(trades.fee, 0) / trades.qty) * #{factor} END"
      internal_movement = ActiveRecord::Base.sanitize_sql_array([
        "COALESCE(trades.investment_activity_label IN (?), FALSE)", Trade::INTERNAL_MOVEMENT_LABELS
      ])

      cutoff = ActiveRecord::Base.sanitize_sql_array(
        if before
          # A row comparison, so it sorts exactly as the reorder below does.
          [ "(entries.date, entries.created_at, entries.id) < (?, ?, ?)", before.date, before.created_at, before.id ]
        else
          [ "entries.date <= ?", through ]
        end
      )

      account.trades
        .with_entry
        .joins(ActiveRecord::Base.sanitize_sql_array([
          "LEFT JOIN exchange_rates ON (
            exchange_rates.date = entries.date AND
            exchange_rates.from_currency = trades.currency AND
            exchange_rates.to_currency = ?
          )", account.currency
        ]))
        .where(security_id: security_id)
        .where("(#{cutoff}) OR entries.date <= ?", date)
        .reorder("entries.date ASC, entries.created_at ASC, entries.id ASC")
        .pluck(Arel.sql("entries.date"), Arel.sql("trades.qty"), Arel.sql(unit_cost), Arel.sql(internal_movement), Arel.sql("COALESCE(#{cutoff}, FALSE)"))
    end
end
