module PortfoliosHelper
  # The period-return card's hint. Ordinarily just the comparison label; when
  # an account has been withheld for want of an exchange rate, it also says so,
  # because a partial figure that does not announce itself reads as a whole one.
  def kpi_period_return_hint(period, unconvertible_count)
    return period.comparison_label if unconvertible_count.to_i.zero?

    "#{period.comparison_label} · " \
      "#{t('portfolios.kpi_row.period_return_unconvertible', count: unconvertible_count)}"
  end
end
