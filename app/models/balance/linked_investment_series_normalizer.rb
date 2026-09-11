class Balance::LinkedInvestmentSeriesNormalizer
  attr_reader :account, :series

  class << self
    def aggregate_accounts(accounts:, currency:, period:, favorable_direction:, interval: "1 day")
      aggregate_account_ids(
        account_ids: Array(accounts).map(&:id),
        currency: currency,
        period: period,
        favorable_direction: favorable_direction,
        interval: interval
      )
    end

    def aggregate_account_ids(account_ids:, currency:, period:, favorable_direction:, interval: "1 day")
      account_ids = Array(account_ids).compact
      series = Balance::ChartSeriesBuilder.new(
        account_ids: account_ids,
        currency: currency,
        period: period,
        favorable_direction: favorable_direction,
        interval: interval
      ).balance_series

      trim_to_supported_history(series, account_ids: account_ids)
    end

    # Drops the points before the date every linked account in `account_ids`
    # has real history for, so a series built from balances alone does not
    # chart flat zeros before a broker's first snapshot. A series the caller
    # built itself (with cut-off dates, or from holdings or gains) gets the
    # same trim as #aggregate_account_ids applies to its own.
    def trim_to_supported_history(series, account_ids:)
      common_start_date = common_supported_history_start_date(Array(account_ids).compact)
      return series unless common_start_date.present?

      trimmed_values = series.values.select { |value| value.date >= common_start_date }
      return series if trimmed_values.blank? || trimmed_values.length == series.values.length

      Series.new(
        start_date: trimmed_values.first.date,
        end_date: series.end_date,
        interval: series.interval,
        values: flatten_first_trend(trimmed_values),
        favorable_direction: series.favorable_direction
      )
    end

    # The first point of a series has nothing before it to compare against --
    # the builders already emit it flat. After a trim the new first point
    # still carries the change against the point that was just removed, so a
    # tooltip would report a move out of history the chart no longer draws.
    def flatten_first_trend(values)
      first = values.first
      return values unless first&.trend

      flat = Series::Value.new(
        date: first.date,
        date_formatted: first.date_formatted,
        value: first.value,
        trend: Trend.new(
          current: first.value,
          previous: first.value,
          favorable_direction: first.trend.favorable_direction
        )
      )

      [ flat, *values.drop(1) ]
    end

    private
      def common_supported_history_start_date(account_ids)
        account_ids = Array(account_ids)
        return if account_ids.empty?

        activity_dates = Entry.where(account_id: account_ids)
          .excluding_pending
          .where.not(source: nil)
          .where.not(entryable_type: "Valuation")
          .group(:account_id)
          .minimum(:date)

        stable_holding_dates = stable_provider_holding_start_dates(account_ids)

        account_ids.filter_map do |account_id|
          [ activity_dates[account_id], stable_holding_dates[account_id] ].compact.min
        end.max
      end

      def stable_provider_holding_start_dates(account_ids)
        rows = Holding.where(account_id: account_ids)
          .where.not(account_provider_id: nil)
          .group(:account_id, :date)
          .order(account_id: :asc, date: :desc)
          .pluck(:account_id, :date, Arel.sql("array_agg(security_id ORDER BY security_id)"))

        rows.group_by(&:first).transform_values do |account_rows|
          _account_id, latest_snapshot_date, latest_security_ids = account_rows.first
          next unless latest_snapshot_date.present?
          next latest_snapshot_date if latest_security_ids.blank?

          stable_dates = account_rows
            .take_while { |_id, _date, security_ids| security_ids == latest_security_ids }
            .map { |_id, date, _security_ids| date }

          stable_dates.last || latest_snapshot_date
        end
      end
  end

  def initialize(account:, series:)
    @account = account
    @series = series
  end

  def normalize
    return series unless account.linked? && account.balance_type == :investment

    first_supported_history_date = supported_history_start_date
    return series unless first_supported_history_date.present?

    trimmed_values = series.values.select { |value| value.date >= first_supported_history_date }
    return series if trimmed_values.blank? || trimmed_values.length == series.values.length

    Series.new(
      start_date: trimmed_values.first.date,
      end_date: series.end_date,
      interval: series.interval,
      values: trimmed_values,
      favorable_direction: series.favorable_direction
    )
  end

  private

    def supported_history_start_date
      [ first_provider_activity_date, stable_provider_holding_start_date ].compact.min
    end

    def first_provider_activity_date
      @first_provider_activity_date ||= account.entries
        .excluding_pending
        .where.not(source: nil)
        .where.not(entryable_type: "Valuation")
        .minimum(:date)
    end

    def provider_holdings_scope
      @provider_holdings_scope ||= account.holdings.where.not(account_provider_id: nil)
    end

    def stable_provider_holding_start_date
      date_security_pairs = provider_holdings_scope
        .group(:date)
        .order(date: :desc)
        .pluck(:date, Arel.sql("array_agg(security_id ORDER BY security_id)"))
      latest_snapshot_date, latest_security_ids = date_security_pairs.first
      return unless latest_snapshot_date.present?
      return latest_snapshot_date if latest_security_ids.blank?

      stable_dates = date_security_pairs
        .take_while { |_date, security_ids| security_ids == latest_security_ids }
        .map(&:first)

      stable_dates.last || latest_snapshot_date
    end
end
