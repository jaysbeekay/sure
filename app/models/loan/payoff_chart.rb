class Loan
  # The series the loan balance chart at the top of a loan's account page
  # draws, and the figures its accessible description quotes (#390).
  #
  #   actual     the recorded balances, origination -> today (or the period's
  #              end, whichever is earlier). Solid: this is fact.
  #   scheduled  the contract, origination -> maturity, re-amortised at each
  #              recorded rate change -- the rows the Schedule tab's table
  #              prints (AmortizationSchedule#display_rows). Dashed.
  #   projected  where today's recorded balance is heading on the schedule's
  #              repayment (Loan::PayoffProjection). Dashed.
  #   extra      the same projection with the Extra repayments tab's modelled
  #              monthly extra. Present only when the caller passes one that
  #              can be projected. Dotted.
  #
  # Ported from upstream's Loan::PayoffChart (we-promise/sure#3474, #4006) and
  # adapted to the fork's engine: origination is `start_date` or the account's
  # opening anchor (the date AmortizationSchedule amortises from), the scheduled
  # rows are display_rows so a stale persisted schedule is never plotted beside
  # live figures (risk R21), and the projection is the fork's PayoffProjection
  # for the caller's `as_of`.
  #
  # The picked period governs the x-domain, and it means what it means on
  # every other chart: 1Y is the last year, YTD the current calendar year,
  # clamped so no window opens before the loan does. Under "All" the domain
  # runs origination -> the later payoff date so every series has room. A
  # bounded window ends today, so the forward series draw under All alone.
  # `Period` is not touched to achieve this: the payload carries the domain
  # and the controller draws to it.
  #
  # The actual series is never queried past `as_of`. Balance::ChartSeriesBuilder
  # carries the last observation forward, so asking it for future dates would
  # draw a flat line asserting the balance never moves again.
  class PayoffChart
    SERIES = %i[actual scheduled projected extra].freeze

    # The periods a loan's chart offers, a subset of the shared Period keys the
    # picker saves as the user's default. The short ones a loan has no use for
    # (7D, 30D, a custom range) are left out; any other Period key, including
    # one added to Period::PERIODS later, shows the whole life, because the
    # picker's choice is shared with every account page. A test keeps these
    # keys a subset of Period::PERIODS so a renamed period cannot silently
    # stop matching.
    WINDOW_KEYS = %w[
      current_month
      last_90_days
      current_year
      last_365_days
      last_5_years
      last_10_years
      all_time
    ].freeze

    # [key, label] pairs for the loan chart's period picker, in WINDOW_KEYS
    # order, under the shared periods' own labels.
    def self.window_options
      WINDOW_KEYS.map { |key| [ key, Period.from_key(key).label_short ] }
    end

    # `projection` lets a caller that also shows the forecast elsewhere on the
    # page build it once; it must be the loan's projection for this `as_of`.
    # `extra_projection` is the Extra repayments tab's projection with the
    # modelled monthly extra, for the same `as_of`, or nil when no amount was
    # entered.
    def initialize(loan, as_of: Date.current, period: nil, projection: nil, extra_projection: nil)
      @loan = loan
      @as_of = as_of
      @period = period
      @projection = projection
      @extra_projection = extra_projection
    end

    # nil when there is nothing to draw. The page falls back to the plain
    # balance chart, so the chart's absence is not the page's absence.
    def payload
      return nil unless schedule.amortizable? && scheduled_rows.any?

      series = {
        actual: actual_series,
        scheduled: scheduled_series,
        projected: projection_series(projection)
      }
      series[:extra] = projection_series(extra_projection) if extra?

      {
        today: as_of.iso8601,
        # The tooltip formats dates and money in this locale. The layout
        # hard-codes `lang="en"`, so the document cannot tell the chart.
        locale: I18n.locale.to_s,
        currency: currency,
        # The split is shown to the currency's own precision, as the Schedule
        # tab shows it. Intl's default can differ from the app's (BTC).
        currency_precision: Money::Currency.new(currency).default_precision || 2,
        domain_start: domain_start.iso8601,
        domain_end: domain_end.iso8601,
        **series,
        visible: SERIES.select { |key| series.key?(key) && visible?(series[key]) },
        scheduled_payoff_date: schedule.payoff_date&.iso8601,
        projected_payoff_date: projection.payoff_date&.iso8601,
        **(extra? ? { extra_payoff_date: extra_projection.payoff_date&.iso8601 } : {}),
        labels: labels,
        aria_description: aria_description(actual: series[:actual])
      }
    end

    private
      attr_reader :loan, :as_of, :period, :extra_projection

      def schedule
        @schedule ||= loan.amortization_schedule
      end

      # Read once: display_rows either loads the persisted rows or recomputes
      # them, and both are work the payload must not repeat per point.
      def scheduled_rows
        @scheduled_rows ||= schedule.display_rows
      end

      def projection
        @projection ||= PayoffProjection.new(loan, as_of: as_of)
      end

      # Only a projection that ran draws a line. One whose extra still leaves
      # the loan unpaid has no payoff to show; the tab says so in words.
      def extra?
        extra_projection.present? && extra_projection.applicable?
      end

      def currency
        loan.account.currency
      end

      # The date AmortizationSchedule amortises from. Memoised: a loan with no
      # start date finds it through the account's opening anchor, and the
      # domain reads it for every point.
      def origination_date
        @origination_date ||= loan.start_date || loan.account_opening_anchor_date
      end

      # No period, "All", and any period the loan chart does not offer -- the
      # picker's choice is shared with every account -- mean the whole life.
      def whole_life?
        period.nil? || period.key.to_s == "all_time" || !WINDOW_KEYS.include?(period.key.to_s)
      end

      # A window opens where the period does, but never before the loan: a
      # lead-in before origination would read as a balance that was not there.
      def domain_start
        @domain_start ||= whole_life? ? origination_date : [ period.start_date, origination_date ].max
      end

      # The whole life reaches far enough to hold every line: the contract's
      # payoff and the projections', whichever is latest, and never before
      # today. A window ends where the period does, but never past that and
      # never on its start.
      def domain_end
        @domain_end ||= begin
          whole_life_end = [
            schedule.payoff_date, projection.payoff_date, (extra_projection.payoff_date if extra?), as_of
          ].compact.max
          whole_life? ? whole_life_end : [ [ period.end_date, whole_life_end ].min, domain_start + 1 ].max
        end
      end

      # Recorded balances inside the domain and no later than `as_of`. Nothing
      # before the first materialised balance: the series builder carries the
      # last observation forward and reports zero before there is one, and a
      # flat zero lead-in reads as a balance that was not there.
      def actual_series
        first_balance_date = loan.account.balances.minimum(:date)
        return [] if first_balance_date.nil?

        from = [ domain_start, first_balance_date ].max
        to = [ domain_end, as_of ].min
        return [] if from > to

        loan.account.balance_series(period: Period.custom(start_date: from, end_date: to)).values.map do |value|
          { date: value.date.iso8601, balance: value.value.amount.to_f }
        end
      end

      # Opens at origination with the amount borrowed. Starting at the first
      # payment omits the amount borrowed entirely, and leaves a one-payment
      # loan with a single point and therefore no line at all.
      #
      # Each payment carries what it is made of, for the tooltip (#21). The
      # opening point is the amount borrowed, not a payment, so it carries no
      # split.
      def scheduled_series
        opening = { date: origination_date.iso8601, balance: loan.original_balance.amount.to_f }
        [ opening ] + scheduled_rows.map do |row|
          { date: row.payment_date.iso8601, balance: row.ending_balance.to_f,
            principal: row.principal_payment.to_f, interest: row.interest_payment.to_f }
        end
      end

      # A projection opens at today's real balance, so the line starts there
      # rather than at its first payment -- otherwise it appears to begin
      # wherever the first payment happens to leave it.
      def projection_series(source)
        return [] unless source&.applicable?

        opening = { date: as_of.iso8601, balance: source.current_balance.amount.to_f }
        [ opening ] + source.payments.map do |payment|
          { date: payment[:payment_date].iso8601, balance: payment[:ending_balance].to_f }
        end
      end

      # A series is worth a legend entry when it draws a line inside the
      # domain: two of its points fall inside, or it enters on one side and
      # leaves on the other. One point on the boundary -- the projection's
      # opening point sits exactly on the end of every period but "All" -- is
      # not a line, and the legend must not promise one.
      def visible?(points)
        dates = points.map { |point| Date.iso8601(point[:date]) }
        return false if dates.empty?

        inside = dates.count { |date| date.between?(domain_start, domain_end) }
        inside >= 2 || (dates.first < domain_start && dates.last > domain_end)
      end

      # The chart controller reads `interactive_chart` for the SVG's
      # aria-roledescription; without it every locale gets its English default.
      def labels
        base = %i[actual scheduled projected].index_with { |key| I18n.t("UI.account.chart.loan.#{key}") }
        base[:extra] = I18n.t("UI.account.chart.loan.extra", amount: extra_projection.extra_payment.format) if extra?
        base.merge(
          # The Schedule tab's column labels, so the tooltip and the table
          # name the same figures the same way.
          principal: I18n.t("loans.tabs.schedule.principal"),
          interest: I18n.t("loans.tabs.schedule.interest"),
          today: I18n.t("UI.account.chart.loan.today"),
          interactive_chart: I18n.t("UI.account.chart.loan.interactive_chart")
        )
      end

      # Every series the chart draws is named here, with its payoff date.
      def aria_description(actual:)
        sentences = [ I18n.t(
          "UI.account.chart.loan.aria_description",
          current_balance: projection.current_balance.format,
          scheduled_payoff_date: long_date(schedule.payoff_date, I18n.t("loans.tabs.overview.unknown")),
          projected_payoff_date: long_date(projection.payoff_date, I18n.t("UI.account.chart.loan.no_payoff"))
        ) ]

        # What the tooltip shows on each scheduled point (#21), in the schedule
        # table's own words.
        sentences << I18n.t(
          "UI.account.chart.loan.aria_composition",
          principal: I18n.t("loans.tabs.schedule.principal"),
          interest: I18n.t("loans.tabs.schedule.interest")
        )

        if extra?
          sentences << I18n.t(
            "UI.account.chart.loan.aria_description_extra",
            amount: extra_projection.extra_payment.format,
            extra_payoff_date: long_date(extra_projection.payoff_date, I18n.t("UI.account.chart.loan.no_payoff"))
          )
        end

        actual_start_date = actual.first && Date.iso8601(actual.first[:date])
        if actual_start_date && actual_start_date > domain_start
          sentences << I18n.t(
            "UI.account.chart.loan.aria_actual_history_starts",
            date: I18n.l(actual_start_date, format: :long)
          )
        end

        sentences.join(" ")
      end

      def long_date(date, fallback)
        date ? I18n.l(date, format: :long) : fallback
      end
  end
end
