# Says so when the month's spending is running ahead of the budget: either on
# course to overshoot it (approaching) or already past it (over). On-track is
# deliberately silent -- BudgetInsightGenerator already emits the quiet
# "everything is within its limit" signal, and a second one would duplicate it.
#
# The classification is Spending::Pace's; this only decides when it is worth a
# card. A projection needs a few days of data to mean anything, so an
# `approaching` verdict waits for MIN_ELAPSED_DAYS. `over` does not wait: it is
# a fact about money already spent, not an extrapolation.
#
# The reference date is injected (defaulting to today) and is the only clock
# this reads.
class Insight::Generators::SpendingPaceGenerator < Insight::Generator
  produces "spending_pace"

  MIN_ELAPSED_DAYS = 7 # same floor as SpendingAnomalyGenerator

  def initialize(family, today: Date.current)
    super(family)
    @today = today
  end

  def generate
    pace = narrative.pace
    return [] unless pace&.over? || (pace&.approaching? && pace.elapsed_days >= MIN_ELAPSED_DAYS)

    [ pace_insight(narrative.budget, pace) ]
  end

  private
    attr_reader :today

    # No viewer: insights are family-wide, so this resolves the household
    # budget (or the only one) exactly as the nightly generators always have.
    def narrative
      @narrative ||= Spending::Narrative.new(family: family, user: nil, on: today, household: true)
    end

    def pace_insight(budget, pace)
      status = pace.status.to_s
      spent_pct = pace.spent_percent

      build_insight(
        insight_type: "spending_pace",
        priority: pace.over? ? "high" : "medium",
        title: I18n.t("insights.titles.spending_pace.#{status}"),
        template_key: "spending_pace.#{status}",
        facts: {
          spent: format_money(pace.spent),
          budgeted: format_money(pace.budgeted),
          spent_pct: spent_pct,
          elapsed_pct: pace.elapsed_percent,
          projected_spend: format_money(pace.projected_spend),
          over_by: format_money([ pace.spent - pace.budgeted, 0 ].max)
        },
        # Spend accrues and the elapsed fraction grows every night, so exact
        # figures here would rewrite the body and resurrect dismissals nightly.
        # The status and a ten-point bucket of the share spent are the
        # material signal; the display numbers live in `facts` only.
        metadata: {
          status: status,
          spent_pct_bucket: (spent_pct / 10) * 10
        },
        period: budget.period,
        dedup_key: "spending_pace:#{month_token(budget.start_date)}"
      )
    end
end
