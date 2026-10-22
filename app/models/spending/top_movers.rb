# Which spending categories moved most between a period and the period of equal
# length before it.
#
# Reads IncomeStatement#net_category_totals, which is built on expense_totals
# and nets refunds against spend category by category -- the same figure the
# budget calls actual spending, so a category here cannot disagree with the
# budget page. A category refunded beyond what was spent is not a net expense
# and counts as zero rather than as a negative mover.
#
# Top-level categories only: net_category_totals already rolls each
# subcategory's spend into its parent.
class Spending::TopMovers
  Mover = Data.define(:category, :current, :previous) do
    def delta
      current - previous
    end

    # A category with nothing in the prior period has no percentage to speak
    # of, so it is flagged new instead of dividing by zero.
    def change_pct
      return nil if previous.zero?

      (delta / previous * 100).round
    end

    def new?
      previous.zero? && current.positive?
    end

    def gone?
      current.zero? && previous.positive?
    end

    def direction
      delta.positive? ? :up : :down
    end

    # A stable identity for the category, including the synthetic buckets
    # (Uncategorized, Other investments), which have no id. Always a String, so
    # a list of keys sorts and serialises whatever mix it holds.
    def key
      Spending::TopMovers.key_for(category)
    end
  end

  def self.key_for(category)
    if category.uncategorized? then "uncategorized"
    elsif category.other_investments? then "other_investments"
    else category.id
    end
  end

  # The window of equal length ending the day before `period` starts -- the
  # idiom ReportsController uses for its own comparison.
  def self.previous_period(period)
    previous_end = period.start_date - 1.day
    Period.custom(start_date: previous_end - (period.days - 1).days, end_date: previous_end)
  end

  def initialize(income_statement:, period:, previous_period: self.class.previous_period(period))
    @income_statement = income_statement
    @period = period
    @previous_period = previous_period
  end

  # Largest absolute change first; ties broken by name so the order is stable.
  def movers(limit: nil)
    current = spend_by_category(period)
    previous = spend_by_category(previous_period)

    ranked = (current.keys | previous.keys).filter_map do |key|
      mover = Mover.new(
        category: (current[key] || previous[key]).fetch(:category),
        current: current.dig(key, :total) || 0.to_d,
        previous: previous.dig(key, :total) || 0.to_d
      )
      mover unless mover.delta.zero?
    end

    ranked = ranked.sort_by { |m| [ -m.delta.abs, m.category.name ] }
    limit ? ranked.first(limit) : ranked
  end

  private
    attr_reader :income_statement, :period, :previous_period

    # { key => { category:, total: } }, keyed by Mover#key so the synthetic
    # categories (which have no id) line up across the two periods.
    def spend_by_category(for_period)
      income_statement.net_category_totals(period: for_period).net_expense_categories.each_with_object({}) do |ct, by_key|
        by_key[self.class.key_for(ct.category)] = { category: ct.category, total: ct.total.to_d }
      end
    end
end
