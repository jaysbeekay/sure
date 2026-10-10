require "test_helper"

# Loan::DailyInterest is the fork's calculation behind Loan::Simulator's
# interest hook (#184, direction C). These are the daily-accrual contract rows
# that used to be asserted against the fork's own simulator loop: they now hold
# for the adapter, and through the hook for every run that passes it.
class Loan::DailyInterestTest < ActiveSupport::TestCase
  # C3, C15: charged once per period, offsets reducing the interest-bearing
  # balance from the day they move. 14 days at 12% on 1,000, then 17 days on
  # nothing: 1000 * 14 * 12 / 100 / 365 = 4.60.
  test "daily accrual is charged once and receives offset change points" do
    interest = Loan::DailyInterest.new(
      day_count_convention: :actual_365,
      offset_for: ->(_from, _to) { [ { date: Date.new(2024, 1, 15), amount: BigDecimal("1000") } ] }
    )

    result = simulate(1_000, [ Date.new(2024, 2, 1) ], rate: 12, interest_for: interest, payment_amount: 1_010)

    assert result.converged?
    assert_equal BigDecimal("4.60"), result.payments.first[:interest_payment]
  end

  test "passes the loan's day-count convention to the accrual engine" do
    interest = Loan::DailyInterest.new(day_count_convention: :actual_actual)

    assert_equal BigDecimal("120"),
      interest.call(from_date: Date.new(2024, 1, 1), to_date: Date.new(2025, 1, 1), balance: 1_000, annual_rate: 12)
  end

  # C7, #25's worked example. 100,000 at 3%, changing to 12% effective
  # 2024-02-15, over 2024-02-01..2024-03-01 (29 days, leap February):
  #   14 days @ 3%  = 115.0685
  #   15 days @ 12% = 493.1507  -> 608.22
  # Charging the whole period at either rate gives 238.36 or 953.42.
  test "daily accrual applies a mid-period rate change only from its effective date" do
    interest = Loan::DailyInterest.new(
      day_count_convention: :actual_365,
      rate_changes: ->(_from, _to) { [ { date: Date.new(2024, 2, 15), rate: BigDecimal("12") } ] }
    )

    assert_equal BigDecimal("608.22"),
      interest.call(from_date: Date.new(2024, 2, 1), to_date: Date.new(2024, 3, 1), balance: 100_000, annual_rate: 3).round(2)
  end

  # C10: the window is half-open. A change ON the closing date belongs to the
  # next window; one ON the opening date governs this one (the simulator hands
  # the opening rate in, so the hook must not undo it).
  test "a change on the closing date is not charged in the window it closes" do
    interest = Loan::DailyInterest.new(
      day_count_convention: :actual_365,
      rate_changes: ->(_from, _to) { [ { date: Date.new(2024, 3, 1), rate: BigDecimal("12") } ] }
    )

    assert_equal BigDecimal("0"),
      interest.call(from_date: Date.new(2024, 2, 1), to_date: Date.new(2024, 3, 1), balance: 1_000, annual_rate: 0)
    assert_equal BigDecimal("10.19"),
      interest.call(from_date: Date.new(2024, 3, 1), to_date: Date.new(2024, 4, 1), balance: 1_000, annual_rate: 12).round(2)
  end

  # C6: an extra repayment reduces the interest-bearing balance from its own
  # date, not from the next payment. 100 repaid on 15 January out of 1,000 at
  # 12%: 14 days on 1,000 and 17 on 900.
  test "an extra repayment reduces interest from its own date" do
    interest = Loan::DailyInterest.new(
      day_count_convention: :actual_365,
      extra_for: ->(_from, _to) { [ { date: Date.new(2024, 1, 15), amount: BigDecimal("100") } ] }
    )

    charged = interest.call(from_date: Date.new(2024, 1, 1), to_date: Date.new(2024, 2, 1), balance: 1_000, annual_rate: 12)

    expected = (BigDecimal("1000") * 14 + BigDecimal("900") * 17) * 12 / 100 / 365
    assert_equal expected.round(10), charged.round(10)
  end

  # C6: one on a payment date is applied before the period that opens on it
  # accrues -- the whole period runs on the reduced balance -- and does not
  # touch the period that closes on it.
  test "an extra repayment on a payment date applies to the period that opens on it" do
    interest = Loan::DailyInterest.new(
      day_count_convention: :actual_365,
      extra_for: ->(_from, _to) { [ { date: Date.new(2024, 2, 1), amount: BigDecimal("100") } ] }
    )

    closing = interest.call(from_date: Date.new(2024, 1, 1), to_date: Date.new(2024, 2, 1), balance: 1_000, annual_rate: 12)
    opening = interest.call(from_date: Date.new(2024, 2, 1), to_date: Date.new(2024, 3, 1), balance: 1_000, annual_rate: 12)

    assert_equal (BigDecimal("1000") * 31 * 12 / 100 / 365).round(10), closing.round(10)
    assert_equal (BigDecimal("900") * 29 * 12 / 100 / 365).round(10), opening.round(10)
  end

  # C9: an extra repayment and an offset movement on one date both apply from
  # that date. 31 days at 12% on 1,000 less 100 repaid, less a 200 offset.
  test "extra repayment and offset movement on one date affect the next period" do
    interest = Loan::DailyInterest.new(
      day_count_convention: :actual_365,
      extra_for: ->(_from, _to) { [ { date: Date.new(2024, 3, 1), amount: BigDecimal("100") } ] },
      offset_for: ->(_from, _to) { [ { date: Date.new(2024, 3, 1), amount: BigDecimal("200") } ] }
    )

    assert_equal BigDecimal("7.13"),
      interest.call(from_date: Date.new(2024, 3, 1), to_date: Date.new(2024, 4, 1), balance: 1_000, annual_rate: 12).round(2)
  end

  test "event order is a fixed contract" do
    assert_equal %i[accrual extra_repayment offset_movement payment re_amortisation], Loan::DailyInterest::EVENT_ORDER
    assert Loan::DailyInterest::EVENT_ORDER.frozen?
  end

  # An event the accrual loop does not handle must raise rather than be
  # silently skipped, so the constant cannot gain a member the calculation
  # ignores.
  test "an event in EVENT_ORDER with no handler raises rather than being skipped" do
    original = Loan::DailyInterest::EVENT_ORDER
    Loan::DailyInterest.send(:remove_const, :EVENT_ORDER)
    Loan::DailyInterest.const_set(:EVENT_ORDER, (original + [ :unhandled_event ]).freeze)

    error = assert_raises(ArgumentError) do
      Loan::DailyInterest.new(day_count_convention: :actual_365)
        .call(from_date: Date.new(2024, 1, 1), to_date: Date.new(2024, 2, 1), balance: 1_000, annual_rate: 12)
    end

    assert_match(/unhandled event in EVENT_ORDER/, error.message)
  ensure
    Loan::DailyInterest.send(:remove_const, :EVENT_ORDER)
    Loan::DailyInterest.const_set(:EVENT_ORDER, original)
  end

  test "asks each source for the period it is charging" do
    asked = []
    interest = Loan::DailyInterest.new(
      day_count_convention: :actual_365,
      rate_changes: ->(from, to) { asked << [ :rate, from, to ]; [] },
      extra_for: ->(from, to) { asked << [ :extra, from, to ]; [] },
      offset_for: ->(from, to) { asked << [ :offset, from, to ]; [] }
    )

    interest.call(from_date: Date.new(2024, 1, 1), to_date: Date.new(2024, 2, 1), balance: 1_000, annual_rate: 12)

    assert_equal %i[extra rate offset].map { |source| [ source, Date.new(2024, 1, 1), Date.new(2024, 2, 1) ] }, asked
  end

  # The loan-built calculation reads the loan's own basis and its recorded
  # rate changes, and a fixed loan's retained rows are not changes.
  test "built for a loan, it charges on the loan's basis and its recorded changes" do
    loan = Loan.new(rate_type: "variable", interest_rate: 3, day_count_convention: "actual_365",
                    variable_rate_schedule: { "2024-02-15" => "12" })

    charged = Loan::DailyInterest.for(loan)
      .call(from_date: Date.new(2024, 2, 1), to_date: Date.new(2024, 3, 1), balance: 100_000, annual_rate: 3)
    assert_equal BigDecimal("608.22"), charged.round(2)

    loan.rate_type = "fixed"
    flat = Loan::DailyInterest.for(loan)
      .call(from_date: Date.new(2024, 2, 1), to_date: Date.new(2024, 3, 1), balance: 100_000, annual_rate: 3)
    assert_equal (BigDecimal("100000") * 29 * 3 / 100 / 365).round(10), flat.round(10)
  end

  private
    def simulate(balance, schedule, rate:, interest_for:, payment_amount:)
      Loan::Simulator.new(
        starting_balance: balance,
        accrual_start_date: Date.new(2024, 1, 1),
        payment_schedule: schedule,
        accrual_rate_for: ->(_date) { rate },
        payment_strategy: :hold,
        payment_amount: payment_amount,
        currency_precision: 2,
        interest_for: interest_for
      ).run
    end
end
