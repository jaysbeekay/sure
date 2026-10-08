# Reports which spending categories moved most this month against the window of
# equal length before it, as one insight per month (rising or falling, whichever
# the biggest mover did).
#
# Worth a card only when the signal is real, so it is held back until:
#   - MIN_ELAPSED_DAYS of the month have gone, as for SpendingAnomalyGenerator;
#   - the comparison window has any spending at all (otherwise every category
#     is "new" and nothing has actually moved);
# and a category counts only if it moved by at least MIN_CHANGE in the family's
# currency and, when it had spend before, by at least MIN_CHANGE_PCT of it.
#
# The reference date is injected (defaulting to today) and is the only clock
# this reads.
class Insight::Generators::TopMoversGenerator < Insight::Generator
  produces "top_movers"

  MIN_ELAPSED_DAYS = 7
  MIN_CHANGE = 50       # currency units; ignore trivial movements
  MIN_CHANGE_PCT = 25   # of the prior spend; a brand new category has no prior to measure against
  MAX_LISTED_CATEGORIES = 3
  CHANGE_BUCKET_PCT = 25

  def initialize(family, today: Date.current)
    super(family)
    @today = today
  end

  def generate
    return [] if narrative.period.days < MIN_ELAPSED_DAYS
    return [] unless narrative.previous_spend.positive?

    movers = narrative.top_movers(limit: nil).select { |mover| significant?(mover) }
    return [] if movers.empty?

    [ movers_insight(movers) ]
  end

  private
    attr_reader :today

    def narrative
      @narrative ||= Spending::Narrative.new(family: family, user: nil, on: today, household: true)
    end

    # Exact comparison, not the rounded display percentage: 24.9% must not pass
    # as 25%.
    def significant?(mover)
      return false if mover.delta.abs < MIN_CHANGE

      mover.previous.zero? || mover.delta.abs * 100 >= mover.previous * MIN_CHANGE_PCT
    end

    # `movers` is already ordered by size of change, so the first decides the
    # direction and the listed names are the largest that moved the same way.
    def movers_insight(movers)
      lead = movers.first
      direction = lead.direction.to_s
      listed = movers.select { |mover| mover.direction == lead.direction }.first(MAX_LISTED_CATEGORIES)

      build_insight(
        insight_type: "top_movers",
        priority: lead.direction == :up ? "medium" : "low",
        title: I18n.t("insights.titles.top_movers.#{direction}", category: lead.category.name),
        template_key: "top_movers.#{direction}",
        facts: {
          categories: listed.map { |mover| mover.category.name }.to_sentence,
          top_category: lead.category.name,
          top_change: format_money(lead.delta.abs),
          days: narrative.previous_period.days
        },
        # The movers shift every night as spend accrues, so the material signal
        # is coarse: who is listed, which way, and a 25-point bucket of the
        # lead's change. The exact amounts live in `facts` only.
        metadata: {
          direction: direction,
          category_ids: listed.map(&:key).sort,
          change_bucket: change_bucket(lead)
        },
        period: narrative.period,
        dedup_key: "top_movers:#{month_token(narrative.period.start_date)}"
      )
    end

    def change_bucket(mover)
      return "new" if mover.new?

      (mover.delta.abs * 100 / mover.previous).to_i / CHANGE_BUCKET_PCT * CHANGE_BUCKET_PCT
    end
end
