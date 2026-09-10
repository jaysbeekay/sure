class InvestmentStatement::Totals
  def initialize(family, account_ids:, date_range:)
    @family = family
    @account_ids = account_ids
    @date_range = date_range
  end

  def call
    return empty_result if @account_ids.empty?

    result = ActiveRecord::Base.connection.select_one(query_sql)

    {
      contributions: result["contributions"]&.to_d || 0,
      withdrawals: result["withdrawals"]&.to_d || 0,
      dividends: result["dividends"]&.to_d || 0,
      interest: result["interest"]&.to_d || 0,
      fees: result["fees"]&.to_d || 0,
      trades_count: result["trades_count"]&.to_i || 0
    }
  end

  private
    def empty_result
      {
        contributions: 0,
        withdrawals: 0,
        dividends: 0,
        interest: 0,
        fees: 0,
        trades_count: 0
      }
    end

    def query_sql
      ActiveRecord::Base.sanitize_sql_array([
        aggregation_sql,
        sql_params
      ])
    end

    # One aggregation over the period's trades and labelled transactions.
    #
    # Contributions and withdrawals are the cash each trade entry records
    # (`ABS(entries.amount)`), unchanged from before this class reported fees.
    # `fees` is reported beside them rather than subtracted out of them,
    # because whether a trade's amount already contains its fee is a property
    # of the writer, not of the row: `Trade::CreateForm` and Binance P2P fold
    # the fee in, Kraken and Binance spot do not, and nothing stored on the
    # entry says which (docs/portfolio/methodology.md, "Provider audit").
    #
    # Inferring it from `qty * price` was tried and removed. `trades.price` is
    # not a second opinion about the cash: it is `numeric(19,10)`, so a
    # sub-1e-10 crypto price stores as 0 and a sale measured against it
    # disappears from the totals; it can be stale or in another currency, and
    # then a buy measured against it doubles; and on the one writer whose sell
    # quantity is already net of its fee (Binance P2P) the comparison charges
    # the fee twice. Each of those was reproduced. The cash on the entry is
    # the only figure that is always exactly what moved, so it is the one
    # reported, and P21 states the consequence: for a writer that folds the
    # fee in, that fee is inside the contribution and in `fees`, so the two
    # do not add up to cash out for every provider.
    #
    # Income is by label, whether the provider stored it as a qty-0 Trade or
    # as a Transaction: the same labels Portfolio::FlowClassifier calls
    # income, read from it so the two cannot drift. Fees are the Fee-labelled
    # entries plus trades.fee on every other trade. Income and fee labels are
    # excluded from the direction buckets rather than relying on qty: 0, so a
    # buy relabelled Dividend is counted once.
    #
    # Missing FX rates preserve InvestmentStatement's existing 1:1 fallback.
    #
    # account_ids is already scoped to the family's visible (draft/active)
    # investment accounts, so the query trusts that input and skips a join back
    # to accounts for family/status filtering. Transactions are narrowed to
    # the income and fee shapes in the WHERE clause, so the rows scanned are
    # the period's trades plus its labelled investment transactions.
    def aggregation_sql
      <<~SQL
        SELECT
          COALESCE(SUM(CASE WHEN trades.qty > 0 AND NOT #{income_or_fee_sql}
            THEN ABS(entries.amount * COALESCE(er.rate, 1)) ELSE 0 END), 0) as contributions,
          COALESCE(SUM(CASE WHEN trades.qty < 0 AND NOT #{income_or_fee_sql}
            THEN ABS(entries.amount * COALESCE(er.rate, 1)) ELSE 0 END), 0) as withdrawals,
          COALESCE(SUM(CASE WHEN #{label_sql} = 'Dividend' THEN ABS(entries.amount * COALESCE(er.rate, 1)) ELSE 0 END), 0) as dividends,
          COALESCE(SUM(CASE WHEN #{label_sql} = 'Interest' THEN ABS(entries.amount * COALESCE(er.rate, 1)) ELSE 0 END), 0) as interest,
          COALESCE(SUM(CASE
            WHEN #{fee_sql} THEN ABS(entries.amount)
            WHEN trades.id IS NOT NULL THEN trades.fee
            ELSE 0
          END * COALESCE(er.rate, 1)), 0) as fees,
          COUNT(trades.id) as trades_count
        FROM entries
        LEFT JOIN trades ON trades.id = entries.entryable_id AND entries.entryable_type = 'Trade'
        LEFT JOIN transactions ON transactions.id = entries.entryable_id AND entries.entryable_type = 'Transaction'
        LEFT JOIN exchange_rates er ON (
          er.date = entries.date AND
          er.from_currency = entries.currency AND
          er.to_currency = :target_currency
        )
        WHERE entries.account_id IN (:account_ids)
          AND entries.date BETWEEN :start_date AND :end_date
          AND entries.excluded = false
          AND (
            entries.entryable_type = 'Trade'
            OR (entries.entryable_type = 'Transaction' AND (#{income_or_fee_sql}) #{pending_exclusion_sql})
          )
      SQL
    end

    # COALESCE keeps an unlabelled entry (NULL) out of every label set.
    def label_sql
      "COALESCE(trades.investment_activity_label, transactions.investment_activity_label, '')"
    end

    def income_or_fee_sql
      "(#{label_sql} IN (#{quote_list(income_labels)}) OR #{fee_sql})"
    end

    # A Fee label, or the fee leg of a linked Transfer (a standard
    # transaction pointing at its transfer), as Portfolio::FlowClassifier
    # defines a fee.
    def fee_sql
      "(#{label_sql} IN (#{quote_list(fee_labels)}) OR (transactions.transfer_id IS NOT NULL AND transactions.kind = 'standard'))"
    end

    def pending_exclusion_sql
      Transaction.pending_providers_sql("transactions")
    end

    def income_labels
      Portfolio::FlowClassifier.labels_for(:income)
    end

    def fee_labels
      Portfolio::FlowClassifier.labels_for(:fee)
    end

    def quote_list(values)
      values.map { |value| ActiveRecord::Base.connection.quote(value) }.join(", ")
    end

    def sql_params
      {
        target_currency: @family.currency,
        account_ids: @account_ids,
        start_date: @date_range.begin,
        end_date: @date_range.end
      }
    end
end
