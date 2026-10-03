# The story of the current budget month for one viewer: pace against the
# budget, what moved against the window before it, and when the spending
# happened. The narrative page and the two insight generators both build on the
# pieces here, so they cannot tell different stories.
#
# `on` is the reference date and is always passed in: this class never reads the
# clock, so everything below -- the period, the elapsed fraction, the previous
# window -- is a function of it.
#
# The period is the month to date: from the start of the family's budget month
# to `on`. Movers and the heatmap read it as it stands, the pace measures spend
# through `on` against the days elapsed (not the budget's whole-month total,
# which would include anything dated after `on`), and the previous period is
# the window of equal length before it, so a half-finished month is compared
# with a like-sized stretch rather than with a whole one.
#
# One account scope for every section. When a budget exists the whole page is
# read through that budget's own income statement (a personal budget counts its
# owner's accounts; the household budget counts what the viewer can see), so a
# transaction cannot be in the movers or the grid and missing from the pace.
class Spending::Narrative
  attr_reader :family, :user, :on

  # `household: true` asks for the household budget (the one family-wide
  # insights are computed against) instead of the viewer's own.
  def initialize(family:, user:, on:, household: false)
    @family = family
    @user = user
    @on = on
    @household = household
  end

  def period
    @period ||= begin
      month_start, = Budget.period_for(on, family: family)
      Period.custom(start_date: month_start, end_date: on)
    end
  end

  def previous_period
    @previous_period ||= Spending::TopMovers.previous_period(period)
  end

  # The budget this page is about. Looked up, never bootstrapped --
  # Budget.find_or_bootstrap writes, and a page view should not create a budget
  # row. nil when none exists for the month, or when the household budget is
  # asked for after the family switched it off (a stale row is not a plan
  # anyone can still use).
  def budget
    return @budget if defined?(@budget)

    month_start, month_end = Budget.period_for(on, family: family)
    owner = budget_owner

    @budget =
      if owner.nil? && family.personal_budgets? && !family.household_budget_enabled?
        nil
      else
        family.budgets.find_by(start_date: month_start, end_date: month_end, user: owner)
      end
    @budget.current_user = user if @budget
    @budget
  end

  def pace
    @pace ||= Spending::Pace.for(budget, on: on, spent: spent)
  end

  # Net spend from the start of the month through `on`.
  def spent
    income_statement.net_category_totals(period: period).total_net_expense.to_d
  end

  # Net spend over the previous window; what a "change" is measured against.
  def previous_spend
    income_statement.net_category_totals(period: previous_period).total_net_expense.to_d
  end

  def top_movers(limit: 5)
    Spending::TopMovers.new(income_statement: income_statement, period: period, previous_period: previous_period).movers(limit: limit)
  end

  def heatmap
    @heatmap ||= Spending::Heatmap.new(income_statement: income_statement, period: period)
  end

  private
    # nil is the household budget. A family without personal budgets has only
    # that one. With them, the viewer's own is the default, and it is also what
    # a request for the household budget falls back to when the family has
    # switched the household budget off.
    def budget_owner
      return nil unless family.personal_budgets?
      return nil if @household && family.household_budget_enabled?

      user
    end

    def income_statement
      @income_statement ||= budget ? budget.income_statement : family.income_statement(user: user)
    end
end
