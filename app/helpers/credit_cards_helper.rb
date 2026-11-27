module CreditCardsHelper
  def credit_card_day_of_month_options
    (1..31).map { |day| [ localized_ordinal(day), day ] }
  end

  def credit_card_day_count_convention_options
    CreditCard::DAY_COUNT_BASES.keys.map do |convention|
      [ t("credit_cards.form.day_count_convention_#{convention}", raise: true), convention ]
    end
  end

  # The Overview's interest figure, worded as what the open cycle costs if the
  # closed statement is not paid in full by its due date. A zero figure means
  # grace applies, so it is shown bare.
  def credit_card_interest_if_unpaid(interest, due_date:, today:)
    return t("credit_cards.tabs.overview.unknown") if interest.nil?

    amount = format_money(interest)
    return amount if interest.zero?
    return t("credit_cards.tabs.overview.interest_if_not_paid", amount: amount) if due_date.nil?

    key = due_date < today ? "interest_not_paid_by" : "interest_if_not_paid_by"
    t("credit_cards.tabs.overview.#{key}", amount: amount, date: l(due_date, format: :short_with_year))
  end

  def credit_card_due_countdown(days)
    return nil if days.nil?
    return t("credit_cards.due.overdue", count: days.abs) if days.negative?

    t("credit_cards.due.in_days", count: days)
  end
end
