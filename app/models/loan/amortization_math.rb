class Loan
  # Shared per-period amortisation math. Kept in one place so a rounding or
  # edge-case fix only has to be made once: the contracted schedule sizes
  # payments from the original balance over the original term, and a
  # re-amortisation part-way through sizes them from the balance then
  # outstanding over the periods still remaining. Two callers, one formula.
  module AmortizationMath
    module_function

    # The level payment that amortises `balance` to zero over
    # `remaining_payments` periods at `monthly_rate` -- the standard annuity
    # formula, and the figure a lender quotes.
    #
    # A zero rate is not a degenerate case to guard against, it is an
    # interest-free loan: the balance divided by the periods left.
    def level_payment(balance:, monthly_rate:, remaining_payments:, currency_precision:)
      return BigDecimal("0") if remaining_payments <= 0 || balance <= 0
      return (balance / remaining_payments).round(currency_precision) if monthly_rate.zero?

      growth = (1 + monthly_rate)**remaining_payments
      ((balance * monthly_rate * growth) / (growth - 1)).round(currency_precision)
    end

    # One period's interest/principal split for a fixed payment against a given
    # balance.
    #
    # `final: true` settles the remaining principal exactly rather than leaving
    # rounding dust, and re-derives the payment from it -- so the last payment
    # of a schedule can differ from the level payment by a few cents, exactly as
    # a lender's own table does.
    def step(balance:, payment:, monthly_rate:, currency_precision:, final: false, interest: nil)
      interest ||= (balance * monthly_rate).round(currency_precision)
      principal = final ? balance : payment - interest

      ending_balance = (balance - principal).round(currency_precision)
      ending_balance = BigDecimal("0") if ending_balance.negative?

      {
        payment_amount: final ? (principal + interest).round(currency_precision) : payment.round(currency_precision),
        principal_payment: principal.round(currency_precision),
        interest_payment: interest.round(currency_precision),
        beginning_balance: balance.round(currency_precision),
        ending_balance: ending_balance
      }
    end
  end
end
