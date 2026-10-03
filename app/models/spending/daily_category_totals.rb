# Signed spend per day and category for a period, in the family's currency.
#
# "Signed" is the point: expenses are positive and refunds negative, so summing
# a category's rows gives exactly the expense-minus-income figure
# IncomeStatement#net_category_totals nets per category. The scoping SQL (which
# transactions count, which accounts, the day's exchange rate) comes from
# IncomeStatement::ScopedTransactionsQuery, the module Totals and
# DailyExpenseTotals use, so this cannot count a transaction they would not.
#
# Rows are grouped by day and by the category's top-level id, rolling a
# subcategory into its parent as IncomeStatement does. Uncategorised spend has a
# nil category id.
class Spending::DailyCategoryTotals
  include IncomeStatement::ScopedTransactionsQuery

  Row = Data.define(:date, :category_id, :total)

  def initialize(family, period:, included_account_ids: nil)
    @family = family
    @period = period
    @date_range = period.date_range
    @included_account_ids = included_account_ids

    validate_date_range!
  end

  def call
    # No finance accounts means no transactions to report
    return [] if @included_account_ids&.empty?

    ActiveRecord::Base.connection.select_all(query_sql).map do |row|
      Row.new(date: row["day"].to_date, category_id: row["category_id"], total: row["total"].to_d)
    end
  end

  private
    def query_sql
      ActiveRecord::Base.sanitize_sql_array([ query_sql_body, sql_params ])
    end

    def transactions_scope
      @family.transactions.visible.excluding_pending.in_period(@period)
    end

    def query_sql_body
      <<~SQL
        SELECT
          ae.date AS day,
          COALESCE(c.parent_id, c.id) AS category_id,
          SUM(#{converted_amount_sql("at")}) AS total
        FROM (#{transactions_scope.to_sql}) at
        #{entries_join_sql("at")}
        #{accounts_join_sql}
        LEFT JOIN categories c ON c.id = at.category_id
        #{exchange_rates_join_sql}
        WHERE at.kind NOT IN (#{budget_excluded_kinds_sql})
          #{investment_activity_label_sql("at")}
          AND ae.excluded = false
          AND a.family_id = :family_id
          AND a.status IN ('draft', 'active')
          AND a.exclude_from_reports = false
          #{exclude_tax_advantaged_sql}
          #{include_finance_accounts_sql}
        GROUP BY ae.date, COALESCE(c.parent_id, c.id)
        ORDER BY ae.date
      SQL
    end

    def sql_params
      params = base_sql_params(start_date: @date_range.begin, end_date: @date_range.end)
      params[:included_account_ids] = @included_account_ids if @included_account_ids
      params
    end
end
