module PortfoliosHelper
  # The holdings table's columns: [sort key or nil, label key, alignment].
  # A nil sort key is a column the table does not sort by.
  HOLDINGS_COLUMNS = [
    [ "name", "security", "text-left" ],
    [ nil, "accounts", "text-right" ],
    [ nil, "qty", "text-right" ],
    [ nil, "avg_cost", "text-right" ],
    [ "value", "value", "text-right" ],
    [ "weight", "weight", "text-right" ],
    [ "return", "unrealized", "text-right" ],
    [ "day_change", "day_change", "text-right" ]
  ].freeze

  # Where a column header links: the same column flips direction, another
  # column opens on its natural direction (names ascending, figures
  # descending). The period and grouping travel with it.
  def holdings_sort_link(key, active_sort:, active_dir:, period:, by:)
    next_dir = if active_sort == key
      active_dir == "asc" ? "desc" : "asc"
    else
      key == "name" ? "asc" : "desc"
    end
    portfolio_path({ period: period.key, sort: key, dir: next_dir, by: by }.compact)
  end

  # The aria-sort value for a column header, or nil when it is not the
  # active sort (the attribute is omitted rather than set to "none").
  def holdings_aria_sort(key, active_sort:, active_dir:)
    return nil unless key && active_sort == key

    active_dir == "asc" ? "ascending" : "descending"
  end

  # Deterministic segment colours for the allocation donut (D5): the chart
  # palette the app already uses for categories, indexed by the segment's
  # position, so a grouping renders the same colours on every reload.
  def allocation_color(index)
    Category::COLORS[index % Category::COLORS.size]
  end

  # The donut-chart controller's segment contract, as the dashboard's
  # outflows donut builds it (id, name, amount, currency, percentage, color).
  def allocation_segments_json(segments, currency:)
    segments.each_with_index.map do |segment, index|
      {
        id: segment.id,
        name: segment.name,
        amount: segment.amount.amount.to_f.round(2),
        currency: currency,
        percentage: segment.weight.to_f.round(1),
        color: allocation_color(index)
      }
    end.to_json
  end

  # The period-return card's hint. Ordinarily just the comparison label; when
  # R13 has withheld an account, it also says so, because a partial figure that
  # does not announce itself reads as a whole one.
  def kpi_period_return_hint(period, unconvertible_count)
    return period.comparison_label if unconvertible_count.to_i.zero?

    "#{period.comparison_label} · " \
      "#{t('portfolios.kpi_row.period_return_unconvertible', count: unconvertible_count)}"
  end

  def allocation_segment_name(segment, by)
    by.to_s == "kind" ? t("portfolios.allocation.kinds.#{segment.name}") : segment.name
  end

  # The same palette, in the same order, as
  # time_series_chart_controller's SERIES_COLORS. Two copies of a list is a
  # cost; the alternative is the legend guessing what the chart drew, which is
  # worse -- a legend that disagrees with its chart is actively misleading.
  # A test asserts the two stay the same length and order.
  #
  # The first entry is `currentColor`: both the legend dot and the chart mount
  # carry `text-primary`, so the baseline follows the theme (gray-900 on light,
  # white on dark) instead of being painted the container's own colour.
  COMPARISON_COLORS = [
    "currentColor",
    "var(--color-blue-500)",
    "var(--color-green-600)",
    "var(--color-yellow-600)",
    "var(--color-destructive)",
    "var(--color-gray-400)"
  ].freeze

  def portfolio_comparison_color(index)
    COMPARISON_COLORS[index % COMPARISON_COLORS.length]
  end
end
