class Loan
  # The three series the payoff chart draws, and the figures its accessible
  # description quotes.
  #
  #   1. the original schedule, origination -> maturity
  #   2. the projection from today's balance, which reflects whatever the
  #      borrower has actually paid so far
  #   3. the same projection under a hypothetical regular extra repayment
  #
  # All three coexist. An earlier design had the hypothesis REPLACE the
  # projection, which is exactly the comparison a borrower is trying to make --
  # "where am I heading, and where would I head if I paid more?" -- and answers
  # it by removing one of the two.
  class PayoffChart
    def initialize(loan, as_of: Date.current, extra_payment: nil)
      @loan = loan
      @as_of = as_of
      @extra_payment = extra_payment
    end

    # nil when there is nothing to draw. The tab renders its table regardless,
    # so the chart's absence is not the tab's absence.
    def payload
      return nil unless schedule&.payments&.any?

      {
        today: as_of.iso8601,
        currency: currency,
        scheduled: series(schedule.payments) { |p| [ p.date, p.ending_balance.amount ] },
        projected: projection_series(projection),
        accelerated: accelerated ? projection_series(accelerated) : [],
        scheduled_payoff_date: schedule.payoff_date&.iso8601,
        projected_payoff_date: projection.payoff_date&.iso8601,
        accelerated_payoff_date: accelerated&.payoff_date&.iso8601,
        labels: labels,
        aria_description: aria_description
      }
    end

    private
      attr_reader :loan, :as_of, :extra_payment

      def schedule
        @schedule ||= loan.amortization_schedule
      end

      def projection
        @projection ||= loan.payoff_projection(as_of: as_of)
      end

      def accelerated
        return nil if extra_payment.blank?

        @accelerated ||= begin
          candidate = loan.payoff_projection(as_of: as_of, extra_payment: extra_payment)
          # Nothing to draw when the hypothesis changed nothing -- an invalid
          # cadence or amount degrades to the baseline, and plotting a third
          # line identical to the second would assert a difference that is not
          # there.
          candidate if candidate.applicable? && candidate.payments.length != projection.payments.length
        end
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
          accelerated: I18n.t("loans.tabs.schedule.chart.accelerated"),
          today: I18n.t("loans.tabs.schedule.chart.today")
        }
      end

      def aria_description
        I18n.t(
          "loans.tabs.schedule.chart.aria_description",
          current_balance: projection.current_balance.format,
          scheduled_payoff_date: schedule.payoff_date ? I18n.l(schedule.payoff_date, format: :long) : I18n.t("loans.tabs.overview.unknown"),
          projected_payoff_date: projection.payoff_date ? I18n.l(projection.payoff_date, format: :long) : I18n.t("loans.tabs.schedule.chart.no_payoff")
        )
      end
  end
end
