module Account::Chartable
  extend ActiveSupport::Concern
  SPARKLINE_CACHE_VERSION = "v4"

  def favorable_direction
    classification == "asset" ? "up" : "down"
  end

  # D5 / FR-501: what "All" means on THIS account's chart.
  #
  # `Period::PERIODS["all_time"]` starts at `Current.family.oldest_entry_date`,
  # which is family-scoped. A loan opened last year in a family with five years
  # of history charts four years of COALESCE-to-zero before the loan exists and
  # then jumps -- a shape that reads as a sudden debt rather than an origination.
  #
  # Deliberately LOAN-ONLY. Account-scoped all-time is a real improvement for
  # every account type, but making it here would change investment, depository
  # and property charts on the back of a loan requirement, with no acceptance
  # criteria for those types and no product sign-off this epic can obtain
  # (risks R10/R11). The general version belongs upstream, with its own
  # fixtures -- see the follow-up issue. `Period::PERIODS` is untouched, so net
  # worth, reports and the dashboard are unaffected by construction.
  def chart_period(requested_period = nil)
    requested_period ||= Period.last_30_days
    return requested_period unless loan_scoped_all_time?(requested_period)

    start_date = chart_start_date

    # Fall back only when the loan's own history is MISSING or not yet begun.
    # An earlier version also fell back when the start date was exactly today,
    # conflating "no history" with "originated today" -- and for a loan
    # originated today that reintroduces the very defect this method exists to
    # remove, charting years of flat zero before it existed. A single-day range
    # is a thin chart; the family-scoped one is a wrong chart.
    return requested_period if start_date.blank? || start_date > Date.current

    # The key is carried across deliberately. `Period.custom` leaves it nil,
    # and UI::PeriodPicker selects on `period.key` -- so a keyless period left
    # the picker with nothing selected and the chart labelled "30D" while
    # showing all-time data. `Period.from_key` builds exactly this shape:
    # a key alongside explicit dates.
    Period.new(key: "all_time", start_date: start_date, end_date: Date.current)
  end

  # Returns the chart Series for this account over the given period.
  # Supported views: :balance, :cash_balance, :holdings_balance, :gains,
  # :net_contributions.
  def balance_series(period: Period.last_30_days, view: :balance, interval: nil)
    raise ArgumentError, "Invalid view type" unless [ :balance, :cash_balance, :holdings_balance, :gains, :net_contributions ].include?(view.to_sym)
    return net_contributions_series(period: period, interval: interval) if view.to_sym == :net_contributions

    builder = chart_series_builder(period: period, interval: interval)

    normalize_linked_investment_series(builder.send("#{view}_series"), view: view)
  end

  # True when a flow the net contributions line counts could not be valued
  # (#326), so the chart can say the line is understated.
  def net_contributions_understated?(period: Period.last_30_days, interval: nil)
    value_dates = balance_series(period: period, view: :balance, interval: interval).values.map(&:date)

    chart_series_builder(period: period, interval: interval)
      .net_contributions_understated?(anchor_date: net_contributions_anchor_date, dates: value_dates)
  end

  def sparkline_series
    cache_key = family.build_cache_key("#{id}_sparkline_#{SPARKLINE_CACHE_VERSION}", invalidate_on_data_updates: true)

    Rails.cache.fetch(cache_key, expires_in: 24.hours) do
      balance_series
    end
  end

  private
    # One builder per period and interval, so the views of one chart share its
    # memoized balance query.
    def chart_series_builder(period:, interval:)
      @balance_series ||= {}

      memo_key = [ period.start_date, period.end_date, interval ].compact.join("_")

      @balance_series[memo_key] ||= Balance::ChartSeriesBuilder.new(
        account_ids: [ id ],
        currency: self.currency,
        period: period,
        favorable_direction: favorable_direction,
        interval: interval
      )
    end

    # Both conditions matter. Only loans, and only the "all_time" key: every
    # other period, and every other account type, is left exactly as the caller
    # asked for. Dropping either half is the bug this branch has to avoid --
    # without the key check it would rewrite 1M and YTD too.
    def loan_scoped_all_time?(period)
      period.key.to_s == "all_time" && accountable.is_a?(Loan)
    end

    # `min(opening anchor, oldest entry)` -- the same expression the balance
    # calculator already uses to decide the earliest date balances exist for.
    # Reused rather than re-derived: a chart that starts before the first
    # materialised balance is the flat-zero segment this method exists to
    # remove, one step earlier.
    def chart_start_date
      Balance::BaseCalculator.new(self).calculation_start_date
    end

    # Net contributions on the same dates as the Total value line (#326).
    #
    # The normalizer does not run on this series: it would prepend a
    # synthetic opening point of its own. Instead the line is sampled on the
    # value line's dates, after that line's trim. For a linked investment
    # account whose value line is trimmed to supported history, the line
    # starts from the balance held before the trim day's activity and counts
    # that day's flows (#382), so the gap between the lines is the market's
    # from the trim date on. The anchor comes from the account's history,
    # not the period, so it is the same whichever period is shown.
    #
    # On the anchor date the line is measured at the same moment as the
    # value line's own point there. That point is the day's close when the
    # balance query sampled it unchanged, and the balance before the day's
    # activity when the normalizer supplied it instead (a coarse interval's
    # prepended opening, or upstream #4009's reset of the first point).
    def net_contributions_series(period:, interval:)
      builder = chart_series_builder(period: period, interval: interval)
      value_series = balance_series(period: period, view: :balance, interval: interval)
      value_dates = value_series.values.map(&:date)
      anchor_date = net_contributions_anchor_date
      series = builder.net_contributions_series(
        anchor_date: anchor_date,
        dates: value_dates,
        anchor_before_activity: value_point_before_activity?(value_series, builder: builder, date: anchor_date)
      )

      Series.new(
        start_date: value_dates.min || series.start_date,
        end_date: series.end_date,
        interval: series.interval,
        values: series.values,
        favorable_direction: series.favorable_direction
      )
    end

    # True when the value line's point on `date` is not the close the
    # balance query gave for that date: the normalizer prepended it or reset
    # it to the balance before the day's activity. False when there is no
    # such point.
    def value_point_before_activity?(value_series, builder:, date:)
      point = date && value_series.values.find { |value| value.date == date }
      return false unless point

      close = builder.balance_series.values.find { |value| value.date == date }
      close.nil? || close.value != point.value
    end

    def net_contributions_anchor_date
      return unless linked? && balance_type == :investment

      Balance::LinkedInvestmentSeriesNormalizer.supported_history_start_date(self)
    end

    def normalize_linked_investment_series(series, view: :balance)
      Balance::LinkedInvestmentSeriesNormalizer.new(account: self, series: series, view: view).normalize
    end
end
