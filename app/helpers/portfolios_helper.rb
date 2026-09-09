module PortfoliosHelper
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
