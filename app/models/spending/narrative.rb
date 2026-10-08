# The story of the current budget month for one viewer: which budget it is
# measured against, how much has been spent so far, and the pace of that spend
# against the budget. Anything presenting these figures builds on the pieces
# here, so two surfaces cannot tell different stories.
#
# `on` is the reference date and is always passed in: this class never reads the
# clock, so everything below -- the period and the elapsed fraction -- is a
# function of it.
#
# The period is the month to date: from the start of the family's budget month
# to `on`. The pace measures spend through `on` against the days elapsed (not
# the budget's whole-month total, which would include anything dated after
# `on`).
#
# One account scope for every figure. When a budget exists everything is read
# through that budget's own income statement (a personal budget counts its
# owner's accounts; the household budget counts what the viewer can see).
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

  # The budget this narrative is about. Looked up, never bootstrapped --
  # Budget.find_or_bootstrap writes, and reading figures should not create a
  # budget row. nil when none exists for the month, or when the household
  # budget is asked for after the family switched it off (a stale row is not a
  # plan anyone can still use).
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
