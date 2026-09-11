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

  def allocation_segment_name(segment, by)
    by.to_s == "kind" ? t("portfolios.allocation.kinds.#{segment.name}") : segment.name
  end
end
