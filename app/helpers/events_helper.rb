module EventsHelper
  # Segments for the shared donut chart: one per category in an event's
  # breakdown. The synthetic "Uncategorized" row has no id of its own.
  def event_donut_segments_json(breakdown)
    breakdown.map do |row|
      {
        id: event_segment_id(row.category),
        name: row.category.name,
        amount: row.total.amount.to_f.round(2),
        currency: row.total.currency.iso_code,
        percentage: row.weight.to_f.round(1),
        color: row.category.color
      }
    end.to_json
  end

  def event_segment_id(category)
    category.persisted? ? category.id : "uncategorized"
  end
end
