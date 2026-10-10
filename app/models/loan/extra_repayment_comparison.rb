class Loan
  # What the Extra repayments tab shows (#304): the loan's projection with an
  # extra amount paid each month, measured against the same projection
  # WITHOUT it. Both projections are built once, on one `as_of`, so the cards
  # and the loan chart at the top of the page (Loan::PayoffChart, #390) can
  # never quote figures from two different "todays".
  #
  # Not persisted, and never writes: like every projection it is computed live
  # from the account's current balance.
  class ExtraRepaymentComparison
    attr_reader :loan, :amount, :as_of

    # `amount` is the raw, request-validated monthly figure, or nil for "no
    # extra entered yet" -- in which case only the baseline is drawn.
    def initialize(loan, amount: nil, as_of: Date.current)
      @loan = loan
      @amount = amount.presence
      @as_of = as_of
    end

    # The loan if nothing extra is paid.
    def baseline
      @baseline ||= PayoffProjection.new(loan, as_of: as_of)
    end

    # The loan with the extra paid each month; nil when no amount was entered.
    def extra
      return nil if amount.nil?
      @extra ||= loan.payoff_projection_with_extra(amount: amount, as_of: as_of)
    end

    # Whether the extra clears the loan. A projection can run without clearing
    # it (Loan::PayoffProjection#applicable? is not #converged?), and one that
    # never clears has no payoff date to show.
    def extra_converged?
      extra.present? && extra.converged?
    end

    # How many payments sooner the extra clears the loan than the baseline.
    def months_sooner
      extra&.months_sooner_than(baseline)
    end

    # Interest the extra saves against not paying it, as Money.
    def interest_saved
      saved = extra&.interest_saved_versus(baseline)
      saved && Money.new(saved, baseline.currency)
    end

    # When the current repayment never clears the loan there is no baseline
    # to chart, so the tab explains instead. Which explanation depends on the
    # amount: none entered yet, one that clears the loan, or one that still
    # doesn't. nil when the baseline converges and the chart is drawn.
    def non_convergence_notice
      return nil unless baseline_does_not_converge?
      return :enter_amount if amount.nil?
      extra_converged? ? :cleared_by_extra : :not_cleared_by_extra
    end

    private
      def baseline_does_not_converge?
        loan.amortizable? &&
          baseline.current_balance.amount.positive? &&
          !baseline.converged?
      end
  end
end
