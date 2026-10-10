class UI::Account::Chart < ApplicationComponent
  attr_reader :account, :loan_chart, :extra_payment_amount

  # `loan_chart` is a Loan::PayoffChart payload, built by the controller for a
  # loan whose schedule can be drawn and nil for everything else. When present
  # the inner chart element becomes the loan balance chart -- recorded balance,
  # schedule, projection and, with an amount from the Extra repayments tab, the
  # extra line, on one axis (#390) -- and the rest of this card (title, hero
  # figure, period picker, Turbo frame) is unchanged. Every other account type
  # takes the branch it always took.
  #
  # `extra_payment_amount` is the request's validated extra amount, so the
  # period picker can carry it: without it a period change would redraw the
  # chart without the extra line.
  #
  # The page's reference date travels inside the payload (`today`), so the
  # component takes no date of its own.
  def initialize(account:, period: nil, view: nil, loan_chart: nil, extra_payment_amount: nil)
    @account = account
    @period = period
    @view = view
    @loan_chart = loan_chart
    @extra_payment_amount = extra_payment_amount.presence
  end

  def loan_chart?
    loan_chart.present?
  end

  def loan_chart_id
    dom_id(account, :loan_chart)
  end

  # The series with a line inside the domain, in drawing order, each with the
  # style the controller gives it. Style is carried by the legend as well as
  # the line: solid is fact, dashed a forecast, dotted the modelled extra, and
  # hue alone would fail in greyscale and under deuteranopia.
  # The colour classes are the functional tokens the controller strokes each
  # line with (`var(--color-success)` and so on), so swatch and line agree.
  LOAN_SERIES_STYLES = {
    "actual" => { swatch: "border-solid border-success" },
    "scheduled" => { swatch: "border-dashed border-destructive" },
    "projected" => { swatch: "border-dashed border-success" },
    "extra" => { swatch: "border-dotted border-info" }
  }.freeze

  def loan_legend
    visible = loan_chart[:visible].map(&:to_s)
    LOAN_SERIES_STYLES.select { |key, _| visible.include?(key) }
  end

  def period
    @effective_period ||= begin
      p = @period || Period.last_30_days
      acc_start = account.history_start_date
      # `acc_start <= p.end_date` is not belt and braces. `Period#initialize`
      # calls `validate!`, which RAISES on a start after its end, so an account
      # whose history begins in the future -- a scheduled opening anchor, a
      # valuation dated ahead, a provider backfill landing tomorrow -- would 500
      # the chart rather than draw a thin one. The fork's `Account#chart_period`
      # guarded this with `start_date > Date.current`; the generalised version
      # adopted from upstream in the A1 sync did not carry the guard, and the
      # eight tests on `chart_period` kept passing because this component had
      # stopped calling it. Expressed against the period's own end rather than
      # against today, since that is the bound the validation actually checks.
      if p.key == "all_time" && acc_start.present? && acc_start > p.start_date && acc_start <= p.end_date
        Period.new(key: "all_time", start_date: acc_start, end_date: p.end_date)
      else
        p
      end
    end
  end

  def holdings_value_money
    account.balance_money - account.cash_balance_money
  end

  # Money value shown as the main indicator for the selected chart view.
  def view_balance_money
    case view
    when "balance"
      account.balance_money
    when "holdings_balance"
      holdings_value_money
    when "cash_balance"
      account.cash_balance_money
    when "gains"
      gains_money
    end
  end

  # Formatted main indicator. Gains are signed explicitly (e.g. "+€79.53") since
  # a gain of zero-or-more is otherwise indistinguishable from a balance.
  def view_balance_display
    signed_format(view_balance_money)
  end

  # Formatted family-currency amount for foreign-currency accounts, signed the
  # same way as the main indicator. Nil when no conversion applies.
  def converted_balance_display
    converted_balance_money&.then { |money| signed_format(money) }
  end

  # Label displayed above the main indicator, based on account type and chart view.
  def title
    case account.accountable_type
    when "Investment", "Crypto"
      case view
      when "balance"
        I18n.t("UI.account.chart.title.total_account_value")
      when "holdings_balance"
        I18n.t("UI.account.chart.title.holdings_value")
      when "cash_balance"
        I18n.t("UI.account.chart.title.cash_value")
      when "gains"
        I18n.t("UI.account.chart.title.total_gains")
      end
    when "Property"
      I18n.t("UI.account.chart.title.estimated_property_value")
    when "Vehicle"
      I18n.t("UI.account.chart.title.estimated_vehicle_value")
    when "CreditCard", "OtherLiability"
      I18n.t("UI.account.chart.title.debt_balance")
    when "Loan"
      I18n.t("UI.account.chart.title.remaining_principal_balance")
    else
      I18n.t("UI.account.chart.title.balance")
    end
  end

  def foreign_currency?
    account.currency != account.family.currency
  end

  # Main indicator converted to the family currency for foreign-currency accounts,
  # or nil when no conversion applies (same currency or missing exchange rate).
  def converted_balance_money
    return nil unless foreign_currency?

    begin
      base_money = view == "gains" ? gains_money : account.balance_money
      base_money.exchange_to(account.family.currency)
    rescue Money::ConversionError
      nil
    end
  end

  def view
    @view ||= "balance"
  end

  def series
    @series ||= account.balance_series(period: period, view: view)
  end

  # #326: the Total value view of an account that holds trades draws a second
  # line, what the owner has put in net of what they took out.
  def show_net_contributions?
    view == "balance" && account.supports_trades?
  end

  # The second line for the chart controller: each point's net contributions
  # and its difference from total value on the same date, signed, with the
  # difference as a percentage of net contributions. Rounded as the value
  # line's own points are, so the tooltip's three figures agree.
  def net_contributions_comparison
    values_by_date = series.values.index_by(&:date)

    points = account.balance_series(period: period, view: :net_contributions).values.filter_map do |point|
      value_point = values_by_date[point.date]
      next unless value_point

      contributions = point.value.for_display
      {
        date: point.date,
        value: contributions,
        difference: Trend.new(current: value_point.value.for_display, previous: contributions)
      }
    end

    {
      label: I18n.t("UI.account.chart.net_contributions.label"),
      difference_label: I18n.t("UI.account.chart.net_contributions.difference"),
      values: points
    }
  end

  # A flow the line counts could not be valued (no exchange rate, or a
  # journalled position with no price that day), so the line is understated
  # and the gap overstates growth. Said under the legend rather than hidden.
  def net_contributions_understated?
    account.net_contributions_understated?(period: period)
  end

  # The legend under the chart names both lines. The value line takes its
  # trend colour from the series, so its swatch does too.
  def net_contributions_legend
    [
      { label: I18n.t("UI.account.chart.views.total_value"), swatch_class: "border-solid", color: series.trend&.color },
      { label: I18n.t("UI.account.chart.net_contributions.label"), swatch_class: "border-dashed border-current text-secondary", color: nil }
    ]
  end

  # Current total unrealized gains, taken from the series so the main indicator
  # always matches the last point of the chart (there is no stored gains column).
  def gains_money
    series.values.last&.value || Money.new(0, account.currency)
  end

  # On a loan chart the change line compares today's balance with the amount
  # borrowed, whatever window is picked: the chart opens on the loan's whole
  # life, so a change "vs. last month" would describe a window it is not
  # showing (owner review of we-promise/sure#3474).
  def trend
    return series.trend unless loan_chart?

    Trend.new(current: account.balance_money, previous: account.loan.original_balance,
              favorable_direction: account.favorable_direction)
  end

  def comparison_label
    return I18n.t("UI.account.chart.loan.since_start") if loan_chart?

    start_date = series.start_date
    return period.comparison_label if start_date.blank?

    if start_date > period.start_date
      I18n.t("UI.account.chart.vs_available_history")
    else
      period.comparison_label
    end
  end

  # A loan's chart offers a subset of the shared periods
  # (Loan::PayoffChart::WINDOW_KEYS); every other chart offers every period.
  def period_picker_options
    Loan::PayoffChart.window_options if loan_chart?
  end

  # A saved period the loan chart does not offer shows the whole life, so its
  # picker reads All.
  def period_picker_selected
    return period unless loan_chart?

    Loan::PayoffChart::WINDOW_KEYS.include?(period.key.to_s) ? period.key.to_s : "all_time"
  end

  # What every period link carries besides `period`. A trades account keeps
  # its view; a loan with an extra amount keeps the amount and the tab it was
  # entered on, so the extra line survives a period change (#390).
  def period_picker_params
    params = account.supports_trades? ? { chart_view: view } : {}
    return params unless loan_chart? && extra_payment_amount

    params.merge(tab: "extra_repayments", extra_payment: { amount: extra_payment_amount })
  end

  private
    # Prefixes positive gains with "+"; other views keep plain Money formatting.
    def signed_format(money)
      return money.format unless view == "gains" && money.amount.positive?

      "+#{money.format}"
    end
end
