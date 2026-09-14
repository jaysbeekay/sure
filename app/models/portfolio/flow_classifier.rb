# The single definition of what counts as an external flow into or out of a set
# of accounts. See docs/portfolio/returns-contract.md rows F1-F9, which this
# class implements and which `portfolio:verify_contract_coverage` holds to its
# tests.
#
# Two forms are generated from one rule table:
#
#   * `#classify(entry)` -- Ruby, for tests and small sets.
#   * `.sql_case(...)`   -- a SQL CASE expression, for the per-day aggregation in
#                           Portfolio::DailyReturns.
#
# They must agree on every entry; PortfolioFlowClassifierParityTest asserts that
# over a corpus covering every row of the table. Editing one form without the
# other is the failure this design exists to make loud.
#
# SCOPE MATTERS. A transfer between two accounts is internal to a scope holding
# both ends and external to a scope holding only one, so the scope is a required
# constructor argument with no default. The same transfer is therefore an
# external contribution to a single account's return and invisible to the
# family's -- which is correct, and is why #128 (contribution limits) can reuse
# this class unchanged.
class Portfolio::FlowClassifier
  # A flow that changes what the scope holds without being a gain or a loss
  # (:external), cash thrown off by the holdings themselves (:income), a cost
  # (:fee), or a movement that leaves the scope's value untouched (:internal).
  CLASSES = %i[external income fee internal].freeze

  # Drawn from Transaction::ACTIVITY_LABELS, which Trade shares.
  INCOME_LABELS = %w[Dividend Interest].freeze
  FEE_LABELS = %w[Fee].freeze

  # Guards the only two values that reach the SQL string uninterpolated by a
  # bind. Both are developer-supplied table aliases, never user input, but the
  # check is cheap and keeps Brakeman's interpolation warning honest.
  SAFE_ALIAS = /\A[a-z_][a-z0-9_]{0,62}\z/

  class UnsafeAliasError < ArgumentError; end

  attr_reader :scope_account_ids

  def initialize(scope_account_ids:)
    @scope_account_ids = Array(scope_account_ids).compact.map(&:to_s).to_set
  end

  # Returns one of CLASSES for a persisted Entry.
  #
  # Order matters and mirrors the SQL CASE exactly: labels are read before the
  # transfer join, because an income entry that happens to sit inside a transfer
  # pair is still income.
  def classify(entry)
    return :internal if entry.excluded? # F9: excluded entries move no money we count

    case entry.entryable_type
    when "Trade"
      classify_trade(entry.entryable)
    when "Transaction"
      classify_transaction(entry)
    else
      # Valuations and anything else: not a flow. A valuation restates the
      # balance, and the restatement is picked up as a revaluation driver from
      # the balances table, not here.
      :internal
    end
  end

  # True when this entry moves value across the scope's boundary.
  def external?(entry)
    classify(entry) == :external
  end

  class << self
    # A SQL CASE expression returning the same class name as #classify, as a
    # lowercase string. Callers supply the aliases they have joined:
    #
    #   entries      -- the entries table
    #   trades       -- LEFT JOIN trades ON entries.entryable_type = 'Trade' ...
    #   transactions -- LEFT JOIN transactions ON ... = 'Transaction' ...
    #   counterpart  -- the entries row on the other leg of a transfer, or NULL
    #
    # The scope is passed as a bind (`:scope_account_ids`), never interpolated.
    def sql_case(entries: "entries", trades: "trades", transactions: "transactions", counterpart: "counterpart_entries")
      e = safe_alias!(entries)
      tr = safe_alias!(trades)
      tx = safe_alias!(transactions)
      ce = safe_alias!(counterpart)

      <<~SQL.squish
        CASE
          WHEN #{e}.excluded THEN 'internal'
          WHEN #{e}.entryable_type = 'Trade'
               AND #{tr}.investment_activity_label IN (#{quoted_list(INCOME_LABELS)}) THEN 'income'
          WHEN #{e}.entryable_type = 'Trade'
               AND #{tr}.investment_activity_label IN (#{quoted_list(FEE_LABELS)}) THEN 'fee'
          WHEN #{e}.entryable_type = 'Trade' THEN 'internal'
          WHEN #{e}.entryable_type = 'Transaction'
               AND #{tx}.investment_activity_label IN (#{quoted_list(INCOME_LABELS)}) THEN 'income'
          WHEN #{e}.entryable_type = 'Transaction'
               AND #{tx}.investment_activity_label IN (#{quoted_list(FEE_LABELS)}) THEN 'fee'
          WHEN #{e}.entryable_type = 'Transaction'
               AND #{ce}.account_id IS NOT NULL
               AND #{ce}.account_id = ANY(array[:scope_account_ids]::uuid[]) THEN 'internal'
          WHEN #{e}.entryable_type = 'Transaction' THEN 'external'
          ELSE 'internal'
        END
      SQL
    end

    # The joins `sql_case` expects. Kept beside it so the two cannot drift.
    def sql_joins(entries: "entries", trades: "trades", transactions: "transactions", counterpart: "counterpart_entries", transfers: "flow_transfers")
      e = safe_alias!(entries)
      tr = safe_alias!(trades)
      tx = safe_alias!(transactions)
      ce = safe_alias!(counterpart)
      tf = safe_alias!(transfers)

      <<~SQL.squish
        LEFT JOIN trades #{tr}
          ON #{e}.entryable_type = 'Trade' AND #{e}.entryable_id = #{tr}.id
        LEFT JOIN transactions #{tx}
          ON #{e}.entryable_type = 'Transaction' AND #{e}.entryable_id = #{tx}.id
        LEFT JOIN transfers #{tf}
          ON #{tf}.inflow_transaction_id = #{tx}.id OR #{tf}.outflow_transaction_id = #{tx}.id
        LEFT JOIN entries #{ce}
          ON #{ce}.entryable_type = 'Transaction'
         AND #{ce}.entryable_id = CASE
               WHEN #{tf}.inflow_transaction_id = #{tx}.id THEN #{tf}.outflow_transaction_id
               ELSE #{tf}.inflow_transaction_id
             END
      SQL
    end

    private
      def safe_alias!(value)
        raise UnsafeAliasError, "unsafe SQL alias: #{value.inspect}" unless value.to_s.match?(SAFE_ALIAS)
        value.to_s
      end

      # The labels are frozen constants, not user input, but they still go
      # through the connection's quoting rather than being pasted in raw.
      def quoted_list(labels)
        labels.map { |label| ActiveRecord::Base.connection.quote(label) }.join(", ")
      end
  end

  private
    # F1-F3.
    def classify_trade(trade)
      label = trade&.investment_activity_label

      return :income if INCOME_LABELS.include?(label)
      return :fee if FEE_LABELS.include?(label)

      # F3. A buy writes cash_outflows and non_cash_inflows of equal magnitude,
      # so end_balance does not move; the balance data already treats every
      # remaining trade shape as internal and this agrees with it.
      :internal
    end

    # F4-F8.
    def classify_transaction(entry)
      transaction = entry.entryable
      label = transaction&.investment_activity_label

      return :income if INCOME_LABELS.include?(label)
      return :fee if FEE_LABELS.include?(label)

      counterpart_account_id = transfer_counterpart_account_id(transaction)

      # F6/F7: internal only when the other end of the transfer is inside the
      # scope. Reading Transaction#kind instead would be wrong here -- the leg
      # that lands in an investment account is written with kind
      # "funds_movement", and it is the *outflow* leg in the funding account
      # that carries "investment_contribution" (Transfer::Creator).
      return :internal if counterpart_account_id && scope_account_ids.include?(counterpart_account_id)

      :external
    end

    def transfer_counterpart_account_id(transaction)
      return nil if transaction.nil?

      transfer = Transfer.find_by(inflow_transaction_id: transaction.id) ||
                 Transfer.find_by(outflow_transaction_id: transaction.id)
      return nil if transfer.nil?

      counterpart = if transfer.inflow_transaction_id == transaction.id
        transfer.outflow_transaction
      else
        transfer.inflow_transaction
      end

      counterpart&.entry&.account_id&.to_s
    end
end
