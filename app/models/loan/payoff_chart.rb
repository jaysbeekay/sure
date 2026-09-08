class Loan
  # The series the payoff chart draws, and the figures its accessible
  # description quotes.
  #
  #   1. the original schedule, origination -> maturity
  #   2. the projection from today's balance, which reflects whatever the
  #      borrower has actually paid so far -- extra payments included, because
  #      it starts from the balance those payments produced
  class PayoffChart
    def initialize(loan, as_of: Date.current)
      @loan = loan
      @as_of = as_of
    end

    # nil when there is nothing to draw. The tab renders its table regardless,
    # so the chart's absence is not the tab's absence.
    def payload
      return nil unless schedule&.payments&.any?

      {
        today: as_of.iso8601,
        currency: currency,
        scheduled: scheduled_series,
        projected: projection_series(projection),
        scheduled_payoff_date: schedule.payoff_date&.iso8601,
        projected_payoff_date: projection.payoff_date&.iso8601,
        labels: labels,
        aria_description: aria_description
      }
    end

    private
      attr_reader :loan, :as_of

      def schedule
        @schedule ||= loan.amortization_schedule
      end

      def projection
        @projection ||= loan.payoff_projection(as_of: as_of)
      end

      def currency
        loan.account.currency
      end

      def series(rows)
        rows.map do |row|
          date, balance = yield(row)
          { date: date.iso8601, balance: balance.to_f }
        end
      end

      # A projection opens at today's real balance, so the line starts there
      # rather than at its first payment -- otherwise it appears to begin
      # wherever the first payment happens to leave it.
      def projection_series(source)
        return [] unless source&.applicable?

        opening = { date: as_of.iso8601, balance: source.current_balance.amount.to_f }
        [ opening ] + series(source.payments) { |p| [ p[:payment_date], p[:ending_balance] ] }
      end

      def labels
        {
          scheduled: I18n.t("loans.tabs.schedule.chart.scheduled"),
          projected: I18n.t("loans.tabs.schedule.chart.projected"),
          today: I18n.t("loans.tabs.schedule.chart.today")
        }
      end

      # Every series the chart draws is named here, with its payoff date.
      def aria_description
        I18n.t(
          "loans.tabs.schedule.chart.aria_description",
          current_balance: projection.current_balance.format,
          scheduled_payoff_date: long_date(schedule.payoff_date, I18n.t("loans.tabs.overview.unknown")),
          projected_payoff_date: long_date(projection.payoff_date, I18n.t("loans.tabs.schedule.chart.no_payoff"))
        )
      end

      def long_date(date, fallback)
        date ? I18n.l(date, format: :long) : fallback
      end

      # Opens at origination with the full principal. Starting at the first
      # payment omits the amount borrowed entirely, and leaves a one-payment
      # loan with a single point and therefore no line at all.
      def scheduled_series
        rows = schedule.payments
        return [] if rows.empty?

        opening = { date: loan.origination_date.iso8601, balance: schedule.principal.to_f }
        [ opening ] + series(rows) { |p| [ p.date, p.ending_balance.amount ] }
      end
  end
end
