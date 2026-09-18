require "test_helper"

# Adopted from `we-promise/sure` in the #184 convergence: the fork's copy and
# upstream's agree for every call the fork makes, and upstream's carries one
# extra path the fork's lacked. That path had no coverage here, so it gets some.
class Loan::AmortizationMathTest < ActiveSupport::TestCase
  RATE = BigDecimal("0.005") # 6% a year, monthly
  BALANCE = BigDecimal("300000")
  TERM = 360

  # The guarantee upstream's comment makes: "with the interest at `monthly_rate`
  # the two formulas agree exactly, so the plain one is kept for the common case
  # and stays bit-identical". If that were only approximately true, adopting the
  # file would move every contracted schedule in the fork by rounding dust.
  test "supplying the interest this period actually charged changes nothing when the rate matches" do
    plain = Loan::AmortizationMath.level_payment(
      balance: BALANCE, monthly_rate: RATE, remaining_payments: TERM, currency_precision: 2
    )

    same_rate_interest = (BALANCE * RATE).round(2)
    told = Loan::AmortizationMath.level_payment(
      balance: BALANCE, monthly_rate: RATE, remaining_payments: TERM,
      currency_precision: 2, first_period_interest: same_rate_interest
    )

    assert_equal plain, told, "the two formulas must agree exactly, not merely closely"
  end

  # The case the extra path exists for. A period that OPENED before a rate change
  # accrues at the old rate but is sized at the new one, and the annuity formula
  # alone assumes every remaining period accrues at `monthly_rate` -- so it
  # over-covers this one and the loan settles short of maturity.
  #
  # Told what this period actually charged, the payment covers it and amortises
  # the rest level. Checked by running the schedule forward rather than against a
  # figure I would otherwise be copying from the implementation.
  test "a period that accrued at the old rate is covered, and the rest amortises level" do
    old_rate = BigDecimal("0.004")
    charged = (BALANCE * old_rate).round(2)

    payment = Loan::AmortizationMath.level_payment(
      balance: BALANCE, monthly_rate: RATE, remaining_payments: TERM,
      currency_precision: 2, first_period_interest: charged
    )

    balance = BALANCE
    TERM.times do |i|
      interest = i.zero? ? charged : (balance * RATE).round(2)
      balance = (balance - (payment - interest)).round(2)
    end

    # Measured: +2.12 on a 300,000 loan over 360 periods -- rounding dust from
    # 360 roundings to the cent, not a sizing error. The naive figure below
    # lands at -1,796.54 on the same run, a whole extra payment.
    assert_operator balance.abs, :<=, BigDecimal("10"),
                    "sized this way the loan lands on zero at maturity, give or take rounding dust"
  end

  # The other side of the boundary: the naive formula on the same straddling
  # period does NOT land on zero, which is the defect the path removes.
  test "the plain formula on the same straddling period settles short" do
    old_rate = BigDecimal("0.004")
    charged = (BALANCE * old_rate).round(2)

    naive = Loan::AmortizationMath.level_payment(
      balance: BALANCE, monthly_rate: RATE, remaining_payments: TERM, currency_precision: 2
    )

    balance = BALANCE
    TERM.times do |i|
      interest = i.zero? ? charged : (balance * RATE).round(2)
      balance = (balance - (naive - interest)).round(2)
    end

    assert_operator balance.abs, :>, BigDecimal("1000"),
                    "if this lands near zero too, the extra path is not buying anything"
  end

  test "a zero rate divides the balance evenly, with or without the interest hint" do
    plain = Loan::AmortizationMath.level_payment(
      balance: BigDecimal("1200"), monthly_rate: BigDecimal("0"), remaining_payments: 12, currency_precision: 2
    )
    assert_equal BigDecimal("100"), plain

    told = Loan::AmortizationMath.level_payment(
      balance: BigDecimal("1200"), monthly_rate: BigDecimal("0"), remaining_payments: 12,
      currency_precision: 2, first_period_interest: BigDecimal("0")
    )
    assert_equal BigDecimal("100"), told
  end
end
