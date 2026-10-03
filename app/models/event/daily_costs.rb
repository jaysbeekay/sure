# Net cost per day (in the family's currency) over a set of transactions: the
# day-by-day series behind an event's chart. Shares its scoping SQL with the
# other IncomeStatement query classes via IncomeStatement::ScopedTransactionsQuery
# so it agrees with their totals, but unlike DailyExpenseTotals it keeps the
# income-classified rows too, as negative amounts, so a refund reduces the day
# it lands on and the days sum to the event's true cost.
class Event::DailyCosts
  include IncomeStatement::ScopedTransactionsQuery

  DayTotal = Data.define(:date, :total)

  def initialize(family, transactions_scope:, date_range:, included_account_ids: nil)
    @family = family
    @transactions_scope = transactions_scope
    @date_range = date_range
    @included_account_ids = included_account_ids

    validate_date_range!
  end

  def call
    return [] if @included_account_ids&.empty?

    ActiveRecord::Base.connection.select_all(query_sql).map do |row|
      DayTotal.new(date: row["day"].to_date, total: row["total"].to_d)
    end
  end

  private
    def query_sql
      ActiveRecord::Base.sanitize_sql_array([ query_sql_body, sql_params ])
    end

    # converted_amount_sql is positive for an expense and negative for an
    # income row (contribution and loan-payment outflows are flipped positive),
    # so a plain SUM is expenses minus refunds.
    def query_sql_body
      <<~SQL
        SELECT
          ae.date AS day,
          SUM(#{converted_amount_sql("at")}) AS total
        FROM (#{@transactions_scope.to_sql}) at
        #{entries_join_sql("at")}
        #{accounts_join_sql}
        #{exchange_rates_join_sql}
        WHERE at.kind NOT IN (#{budget_excluded_kinds_sql})
          #{investment_activity_label_sql("at")}
          AND ae.excluded = false
          AND a.family_id = :family_id
          AND a.status IN ('draft', 'active')
          AND a.exclude_from_reports = false
          #{exclude_tax_advantaged_sql}
          #{include_finance_accounts_sql}
        GROUP BY ae.date
        ORDER BY ae.date
      SQL
    end

    def sql_params
      params = base_sql_params(start_date: @date_range.begin, end_date: @date_range.end)
      params[:included_account_ids] = @included_account_ids if @included_account_ids
      params
    end
end
