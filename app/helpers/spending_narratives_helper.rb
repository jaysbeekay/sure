module SpendingNarrativesHelper
  # One class per heat level. Written out in full (not assembled from a
  # fragment) so Tailwind's scanner finds each token; all are design-system
  # functional tokens, never raw palette classes.
  HEAT_CLASSES = {
    0 => nil,
    1 => "bg-warning/10",
    2 => "bg-warning/20",
    3 => "bg-warning/40",
    4 => "bg-warning/60"
  }.freeze

  HeatmapCell = Data.define(:date, :total, :href, :level)
  HeatmapRow = Data.define(:label, :href, :cells, :total)

  # Quarters of the peak: (0, 25%] is level 1 and so on up to level 4. Zero,
  # a refund-only day or an empty grid (no positive peak) are not heated.
  def spending_heat_level(total, peak)
    return 0 unless total.to_d.positive? && peak.to_d.positive?

    [ (total.to_d * 4 / peak.to_d).ceil, 4 ].min
  end

  def spending_heat_class_for_level(level)
    HEAT_CLASSES.fetch(level)
  end

  # Click-through into the transactions list. The search takes categories and a
  # date range; it has no weekday filter, so a heatmap cell links to its own
  # date and a week row to its week's range.
  def spending_range_path(start_date, end_date)
    transactions_path(q: { start_date: start_date.to_s, end_date: end_date.to_s })
  end

  # nil for "Other investments": it is a synthetic bucket, and no category
  # filter on the transactions list can express it.
  def spending_category_path(category, period)
    return nil if category.other_investments?

    transactions_path(q: {
      categories: [ category.filter_value ],
      start_date: period.start_date.to_s,
      end_date: period.end_date.to_s
    })
  end

  def spending_pace_tone(pace)
    case pace.status
    when :over then :error
    when :approaching then :warning
    else :success
    end
  end

  def spending_pace_bar_class(pace)
    case pace.status
    when :over then "bg-destructive"
    when :approaching then "bg-warning"
    else "bg-success"
    end
  end

  def spending_money(amount)
    Money.new(amount, Current.family.currency).format
  end

  # The table's rows: one per week of the period, then a last row summing each
  # weekday across the period. Each row is a HeatmapRow of seven cells (nil for
  # a date outside the period) and a row total.
  def spending_heatmap_rows(heatmap)
    peak = heatmap.peak

    rows = heatmap.weeks.map do |week|
      cells = week.cells.map do |cell|
        next nil unless cell

        HeatmapCell.new(
          date: cell.date,
          total: cell.total,
          href: (spending_range_path(cell.date, cell.date) unless cell.total.zero?),
          level: spending_heat_level(cell.total, peak)
        )
      end

      HeatmapRow.new(
        label: spending_week_label(week),
        href: spending_range_path(week.start_date, week.end_date),
        cells: cells,
        total: HeatmapCell.new(date: nil, total: week.cells.compact.sum(&:total), href: nil, level: 0)
      )
    end

    weekday_totals = heatmap.weekday_totals
    weekday_peak = weekday_totals.max.to_d

    rows << HeatmapRow.new(
      label: t("spending_narratives.heatmap.weekday_totals"),
      href: nil,
      cells: weekday_totals.map { |total| HeatmapCell.new(date: nil, total: total, href: nil, level: spending_heat_level(total, weekday_peak)) },
      total: HeatmapCell.new(date: nil, total: heatmap.total, href: nil, level: 0)
    )
  end

  # "+$200.00 (+25%)", "+$200.00 (new)" for a category with no prior spend.
  def spending_change_label(mover)
    sign = mover.delta.positive? ? "+" : "−"
    amount = "#{sign}#{spending_money(mover.delta.abs)}"
    pct = mover.change_pct
    detail = pct.nil? ? t("spending_narratives.movers.new") : "#{pct.positive? ? "+" : "−"}#{pct.abs}%"

    "#{amount} (#{detail})"
  end

  private
    def spending_week_label(week)
      if week.start_date == week.end_date
        l(week.start_date, format: :short)
      else
        t("spending_narratives.heatmap.week_label", from: l(week.start_date, format: :short), to: l(week.end_date, format: :short))
      end
    end
end
