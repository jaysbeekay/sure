# Nudges the family to re-value accounts whose worth only changes when someone
# says so: a house, a car, an asset or debt with no provider feeding it. Low
# priority by design -- it is a reminder, not a warning. The dedup key rotates
# monthly, like most generators here, so a dismissed nudge stays gone for the
# rest of the month and returns if the account is still unvalued.
class Insight::Generators::StaleValuationGenerator < Insight::Generator
  produces "stale_valuation"

  MANUALLY_VALUED_TYPES = %w[Property Vehicle OtherAsset OtherLiability].freeze
  MAX_INSIGHTS = 3

  def generate
    today = Date.current

    stale_accounts(today).first(MAX_INSIGHTS).map do |account, last_valued_on|
      build_insight(
        insight_type: "stale_valuation",
        priority: "low",
        title: I18n.t("insights.titles.stale_valuation", account: account.name),
        template_key: "stale_valuation",
        facts: {
          account: account.name,
          balance: Money.new(account.balance, account.currency).format,
          last_valued_on: I18n.l(last_valued_on, format: :long)
        },
        # The account and the date it was last valued are the signal. The balance
        # changes with every valuation and would rewrite the body, and resurface
        # a dismissed card, for no new reason -- so it stays in `facts`.
        metadata: {
          account_id: account.id,
          last_valued_on: last_valued_on.iso8601
        },
        dedup_key: "stale_valuation:#{account.id}:#{month_token(today)}"
      )
    end
  end

  private
    # [account, last_valued_on] pairs, oldest first. Ties break on id so the pick
    # is stable between runs; an unordered cut could nudge a different account
    # each night and churn the feed.
    def stale_accounts(today)
      cutoff = today - family.stale_valuation_days

      candidates = family.accounts.where(status: "active").manual.where(accountable_type: MANUALLY_VALUED_TYPES).to_a
      latest_valuation_dates = Entry.where(account_id: candidates.map(&:id), entryable_type: "Valuation")
        .group(:account_id).maximum(:date)

      candidates
        .map { |account| [ account, last_valued_on(account, latest_valuation_dates[account.id]) ] }
        .select { |_account, last_valued_on| last_valued_on < cutoff }
        .sort_by { |account, last_valued_on| [ last_valued_on, account.id ] }
    end

    # The newest valuation, floored at the day the account was created. Opening
    # anchors are back-dated by design, so an account added today with an opening
    # value from two years ago has not gone two years unvalued.
    def last_valued_on(account, latest_valuation_date)
      [ latest_valuation_date, account.created_at.to_date ].compact.max
    end
end
