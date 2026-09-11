class UI::PeriodPicker < ApplicationComponent
  # Unified time-range selector shared by the dashboard and account charts.
  #
  # Renders a DS::Menu as a flat list of link items — one per Period. Each item
  # is a GET link to `url` carrying `?period=<key>` (plus any `extra_params`),
  # which re-renders `frame` (a Turbo Frame id) with the chosen period. When
  # `frame` is nil the links fall back to a normal Turbo Drive visit.
  #
  # The selected period is marked with a check icon and `aria-current`, and the
  # trigger button shows its label.
  #
  # NOTE: `url` must be a path without a query string; pass query state via
  # `extra_params` so the picker can compose `?period=…` cleanly.
  attr_reader :selected_key, :url, :frame, :extra_params, :placement, :options

  # `options` narrows the menu to [key, label] pairs, for a chart that offers
  # its own timescales under the shared period keys (the loan chart). Without
  # it every Period is offered under its own short label.
  def initialize(selected:, url:, frame: nil, extra_params: {}, placement: "bottom-end", options: nil)
    @selected_key = selected.respond_to?(:key) ? selected.key : selected.to_s
    @url = url
    @frame = frame
    @extra_params = (extra_params || {}).symbolize_keys
    @placement = placement
    @options = options
  end

  # [key, label] pairs, in menu order.
  def items
    options || Period.all.map { |period| [ period.key, period.label_short ] }
  end

  def selected_label
    options&.to_h&.fetch(selected_key, nil) || period_for(selected_key).label_short
  end

  def selected?(key)
    key == selected_key
  end

  def href_for(key)
    "#{url}?#{extra_params.merge(period: key).to_query}"
  end

  private
    def period_for(key)
      Period.from_key(key)
    rescue Period::InvalidKeyError
      Period.last_30_days
    end
end
