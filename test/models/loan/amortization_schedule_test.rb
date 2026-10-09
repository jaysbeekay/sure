require "test_helper"

class Loan::AmortizationScheduleTest < ActiveSupport::TestCase
  test "builds one payment per month of the term" do
    schedule = build_schedule

    assert_equal 360, schedule.payments.count
    assert_equal 1, schedule.payments.first.number
    assert_equal 360, schedule.payments.last.number
  end

  test "level payment matches the standard amortization formula" do
    assert_equal BigDecimal("2245.22"), build_schedule.periodic_payment.amount
  end

  test "first payment is mostly interest and last payment is mostly principal" do
    schedule = build_schedule
    first = schedule.payments.first
    last = schedule.payments.last

    # 500,000 at 3.5% => 1,458.33 of interest in month one.
    assert_equal BigDecimal("1458.33"), first.interest.amount
    assert_equal BigDecimal("786.89"), first.principal.amount
    assert first.interest.amount > first.principal.amount
    assert last.principal.amount > last.interest.amount
  end

  test "amortizes down to exactly zero" do
    assert_equal BigDecimal("0"), build_schedule.payments.last.ending_balance.amount
  end

  test "principal portions sum to the original principal" do
    schedule = build_schedule
    total_principal = schedule.payments.sum(BigDecimal(0)) { |payment| payment.principal.amount }

    assert_equal BigDecimal("500000"), total_principal
  end

  test "total paid is principal plus total interest" do
    schedule = build_schedule

    # Slightly above the naive payment*term figure because interest is rounded
    # to cents every month, exactly as a lender's table does.
    assert_equal BigDecimal("308281.36"), schedule.total_interest.amount
    assert_equal schedule.principal + schedule.total_interest.amount, schedule.total_paid.amount
  end

  test "payment dates step monthly from origination" do
    schedule = build_schedule(start_date: Date.new(2026, 1, 31))

    assert_equal Date.new(2026, 2, 28), schedule.payments.first.date
    assert_equal Date.new(2026, 3, 31), schedule.payments.second.date
  end

  test "payoff date is the last payment date" do
    schedule = build_schedule(start_date: Date.new(2026, 1, 1), term_months: 12)

    assert_equal Date.new(2027, 1, 1), schedule.payoff_date
  end

  test "handles a zero-interest loan with straight-line principal" do
    schedule = build_schedule(annual_rate: 0, term_months: 10, principal: 1000)

    assert_equal BigDecimal("100"), schedule.periodic_payment.amount
    assert schedule.payments.all? { |payment| payment.interest.amount.zero? }
    assert_equal BigDecimal("0"), schedule.total_interest.amount
    assert_equal BigDecimal("0"), schedule.payments.last.ending_balance.amount
  end

  test "rounds to whole units for a currency without minor units" do
    schedule = build_schedule(currency: "JPY", principal: 1_000_000, annual_rate: 2, term_months: 12)

    assert schedule.payments.all? { |payment| payment.payment.amount.frac.zero? }
    assert_equal BigDecimal("0"), schedule.payments.last.ending_balance.amount
  end

  test "returns no payments when the term is zero" do
    assert_empty build_schedule(term_months: 0).payments
    assert_nil build_schedule(term_months: 0).payoff_date
    assert_equal BigDecimal("0"), build_schedule(term_months: 0).periodic_payment.amount
    assert_equal BigDecimal("0"), build_schedule(principal: 0).periodic_payment.amount
  end

  test "keeps the periods it built when rounding clears the balance early" do
    # 10 over 51 months rounds to a 0.20 payment, which pays the loan off in 50.
    schedule = build_schedule(principal: 10, annual_rate: 0, term_months: 51)

    assert_equal 50, schedule.payments.count
    assert_equal BigDecimal("0"), schedule.payments.last.ending_balance.amount
    assert_equal BigDecimal("10"), schedule.total_paid.amount
    assert_equal schedule.payments.last.date, schedule.payoff_date
  end

  test "payment_for finds the payment landing in a given month" do
    schedule = build_schedule(start_date: Date.new(2026, 1, 1), term_months: 12)

    assert_equal 3, schedule.payment_for(Date.new(2026, 4, 17)).number
    assert_nil schedule.payment_for(Date.new(2030, 1, 1))
  end

  test "builds from a loan record" do
    loan = loan_account(interest_rate: 3.5, term_months: 360, rate_type: "fixed").loan

    assert_equal BigDecimal("2245.22"), Loan::AmortizationSchedule.for(loan).periodic_payment.amount
  end

  # Reversed by #104. A variable loan was excluded while a schedule could only
  # be built off one rate; it now re-amortises at each recorded change, so the
  # reason for the exclusion is gone.
  test "is buildable for a variable rate loan" do
    loan = loan_account(interest_rate: 3.5, term_months: 360, rate_type: "variable").loan

    assert_not_nil Loan::AmortizationSchedule.for(loan)
  end

  # Fork divergence (#14): upstream schedules a provider's own rate type as a
  # variable loan (#100 decision 8); the fork schedules only the rate types in
  # Loan::AMORTIZABLE_RATE_TYPES, the one list loans:schedule_version_status
  # also filters on in SQL. A provider's "teaser" gets no schedule here, as it
  # had none before.
  test "is not buildable for a provider's own rate type outside the fork's list" do
    loan = loan_account(interest_rate: 3.5, term_months: 360, rate_type: "teaser").loan

    assert_nil Loan::AmortizationSchedule.for(loan)
  end

  # What is still not buildable: no rate type at all.
  test "is not buildable for a blank rate type" do
    loan = loan_account(interest_rate: 3.5, term_months: 360, rate_type: "").loan

    assert_nil Loan::AmortizationSchedule.for(loan)
  end

  # ---------------------------------------------------------------------------
  # Fork: the schedule a Loan builds, through the interest hook and the
  # persisted-row shape (#184, direction C). Everything above is upstream's
  # schedule suite.
  # ---------------------------------------------------------------------------

  test "a loan's schedule charges through the loan's daily interest, on its own day-count basis" do
    loan = mortgage.loan
    loan.update!(day_count_convention: "actual_actual")

    Loan::Simulator.expects(:new).with do |kwargs|
      kwargs[:interest_for].is_a?(Loan::DailyInterest) && kwargs[:interest_for].day_count_convention == "actual_actual"
    end.returns(stub(run: Loan::SimulationResult.new(payments: [], currency_precision: 2)))

    Loan::AmortizationSchedule.for(loan).payments
  end

  test "a fixed loan with a principal, a rate and a term is amortizable" do
    assert mortgage.loan.amortizable?
    assert_not_nil mortgage.loan.amortization_schedule
  end

  test "a variable loan with a base interest rate is amortizable" do
    loan = mortgage(rate_type: "variable").loan

    assert loan.amortizable?
    assert_equal 360, loan.amortization_schedule.payments.length
  end

  test "a variable loan without an interest rate has no schedule" do
    loan = mortgage(rate_type: "variable", interest_rate: nil).loan

    assert_not loan.amortizable?
    assert_nil loan.amortization_schedule
  end

  # A row's interest_rate is the rate its period OPENED on (upstream's row,
  # #184): a change effective on a payment date sizes that payment, and is
  # charged from the period that opens on it.
  test "a rate change on a payment date is charged from the period that opens on it" do
    loan = mortgage(rate_type: "variable", start_date: 2.years.ago.to_date).loan
    loan.add_variable_rate_change(loan.start_date, 3.5)
    loan.add_variable_rate_change(loan.start_date + 12.months, 4.5)

    rows = loan.amortization_rows
    on_change = rows.index { |row| row[:payment_date] == loan.start_date + 12.months }

    assert_equal BigDecimal("3.5"), rows[on_change][:interest_rate], "the period closing on the change ran at 3.5%"
    assert_equal BigDecimal("4.5"), rows[on_change + 1][:interest_rate], "the period opening on it runs at 4.5%"
    assert_not_equal rows[on_change - 1][:payment_amount], rows[on_change][:payment_amount],
      "the payment on the change date is resized"
  end

  # Loan#amortization_rows re-derives the two figures upstream's Payment does
  # not carry -- the opening balance and the opening rate -- so they are held
  # to the simulator's own row, on a loan with a change on a payment date and
  # one part-way through a period.
  test "a loan's rows carry the simulator's own opening balance and rate" do
    loan = mortgage(rate_type: "variable", term_months: 24, start_date: Date.new(2024, 1, 15),
                    variable_rate_schedule: { "2024-05-15" => "5.0", "2024-09-02" => "6.25" }).loan

    simulated = loan.amortization_schedule.send(:simulation).payments

    assert_equal simulated.map { |row| row.slice(:payment_number, :beginning_balance, :interest_rate) },
      loan.amortization_rows.map { |row| row.slice(:payment_number, :beginning_balance, :interest_rate) }
  end

  test "two changes inside one period: it opens on the old rate and the next on the later one" do
    loan = mortgage(rate_type: "variable", term_months: 6, start_date: Date.new(2023, 1, 1)).loan
    loan.add_variable_rate_change(Date.new(2023, 2, 15), 4.5)
    loan.add_variable_rate_change(Date.new(2023, 2, 20), 5.5)

    rows = loan.amortization_rows

    assert_equal 6, rows.length
    assert_equal [ Date.new(2023, 2, 1), Date.new(2023, 3, 1), Date.new(2023, 4, 1) ], rows.first(3).map { |row| row[:payment_date] }
    assert_equal [ BigDecimal("3.5"), BigDecimal("3.5"), BigDecimal("5.5") ], rows.first(3).map { |row| row[:interest_rate] }
  end

  test "a rate change after maturity adds no payments" do
    loan = mortgage(rate_type: "variable", term_months: 6, start_date: Date.new(2023, 1, 1)).loan
    loan.add_variable_rate_change(Date.new(2025, 1, 1), 5.5)

    assert_equal 6, loan.amortization_schedule.payments.length
  end

  # FR-205 markers follow the accrual clock (C7), not the payment-sizing
  # clock (C8). Comparing consecutive rows' rates gets both of these wrong.
  test "the rate-change marker falls on the payment whose accrual period carries the new rate" do
    loan = marker_loan
    payment_dates = loan.amortization_schedule.payments.map(&:date)

    # Effective ON payment 4's date: it governs [payment 4, payment 5), so
    # payment 5 is the first the borrower is charged the new rate on.
    loan.add_variable_rate_change(payment_dates[3], 9.5)

    assert_equal({ 5 => BigDecimal("9.5") }, loan.accrual_rate_change_markers(loan.amortization_schedule.payments))
  end

  test "a rate change that reverts inside one payment period is still marked" do
    loan = marker_loan
    payment_dates = loan.amortization_schedule.payments.map(&:date)

    loan.add_variable_rate_change(payment_dates[2] + 5, 9.5)
    loan.add_variable_rate_change(payment_dates[2] + 12, 3.5)

    assert_equal [ 4 ], loan.accrual_rate_change_markers(loan.amortization_schedule.payments).keys
  end

  # #14: `adjustable` schedules off the variable path.
  test "an adjustable-rate loan is amortizable and honours its rate changes" do
    loan = marker_loan
    loan.update!(rate_type: "adjustable")

    assert loan.amortizable?, "selecting Adjustable must not silently remove the schedule"

    payment_dates = loan.amortization_schedule.payments.map(&:date)
    loan.add_variable_rate_change(payment_dates[3], 9.5)

    assert_equal({ 5 => BigDecimal("9.5") }, loan.accrual_rate_change_markers(loan.amortization_schedule.payments))
  end

  test "a fixed-rate loan has no rate-change markers" do
    loan = mortgage.loan

    assert_empty loan.accrual_rate_change_markers(loan.amortization_schedule.payments)
  end

  test "the opening payment reflects a rate change before the first payment date" do
    loan = mortgage(rate_type: "variable", start_date: Date.new(2023, 1, 1)).loan
    loan.add_variable_rate_change(Date.new(2023, 1, 15), 5.5)

    schedule = loan.amortization_schedule
    assert_equal schedule.payments.first.payment, schedule.periodic_payment
    assert_operator schedule.periodic_payment.amount, :>, BigDecimal("2245.22"), "sized above the 3.5% annuity"
  end

  test "a zero principal is not amortizable" do
    loan = mortgage(balance: 0).loan

    assert_not loan.amortizable?
    assert_nil loan.amortization_schedule
  end

  test "rejects zero or negative term at the validation layer" do
    loan = Loan.new(rate_type: "fixed", interest_rate: 3.5, term_months: 0)
    assert_not loan.valid?
    assert_includes loan.errors[:term_months], "must be greater than 0"
  end

  test "rejects a term months beyond the supported maximum" do
    loan = Loan.new(rate_type: "fixed", interest_rate: 3.5, term_months: Loan::MAX_TERM_MONTHS + 1)
    assert_not loan.valid?
    assert_includes loan.errors[:term_months], "must be less than or equal to #{Loan::MAX_TERM_MONTHS}"
  end

  test "a zero term is not amortizable" do
    account = Account.new(family: families(:dylan_family), name: "Zero Term", balance: 500_000, currency: "USD",
                          accountable: Loan.new(rate_type: "fixed", interest_rate: 3.5, term_months: 0))

    assert_not account.loan.amortizable?
    assert_nil account.loan.amortization_schedule
  end

  test "a loan with no rate has no monthly payment and no schedule" do
    loan = mortgage(interest_rate: nil).loan

    assert_nil loan.monthly_payment
    assert_nil loan.amortization_schedule
  end

  test "a same-rate change part-way through still amortizes over the whole term" do
    loan = mortgage(rate_type: "variable", start_date: Date.new(2020, 1, 1)).loan
    loan.add_variable_rate_change(loan.start_date + 300.months, 3.5)

    assert_equal BigDecimal("2245.22"), loan.amortization_schedule.periodic_payment.amount
  end

  test "a rate change landing in a short calendar month is not skipped" do
    loan = mortgage(rate_type: "variable", start_date: Date.new(2023, 1, 1)).loan
    loan.add_variable_rate_change(Date.new(2023, 3, 1), 4.5)

    rows = loan.amortization_rows

    assert_equal 360, rows.length
    assert_equal [ Date.new(2023, 2, 1), Date.new(2023, 3, 1), Date.new(2023, 4, 1) ], rows.first(3).map { |row| row[:payment_date] }
    assert_equal [ BigDecimal("3.5"), BigDecimal("3.5"), BigDecimal("4.5") ], rows.first(3).map { |row| row[:interest_rate] }
  end

  # C5: start_date is the origination/anchor date, not the first payment date.
  test "the first payment date is one calendar month after start_date, regardless of its day-of-month" do
    assert_equal Date.new(2024, 2, 1),
      mortgage(term_months: 12, start_date: Date.new(2024, 1, 1)).loan.amortization_schedule.payments.first.date
    assert_equal Date.new(2024, 2, 15),
      mortgage(term_months: 12, start_date: Date.new(2024, 1, 15)).loan.amortization_schedule.payments.first.date
  end

  # C5, upstream's calendar (#184): each date is `origination >> n`, so an
  # anchor on the 31st clamps into a short month and pays on the 31st again
  # after it. The fork's chained `next_month` stayed on the 29th for the rest
  # of the loan; adopting upstream's engine moved those dates.
  test "an anchor on the 31st clamps into a short month and recovers after it" do
    dates = mortgage(term_months: 3, start_date: Date.new(2024, 1, 31)).loan.amortization_schedule.payments.map(&:date)

    assert_equal [ Date.new(2024, 2, 29), Date.new(2024, 3, 31), Date.new(2024, 4, 30) ], dates
  end

  test "a zero interest rate repays straight-line principal" do
    assert_equal BigDecimal("1000"), mortgage(balance: 120_000, interest_rate: 0, term_months: 120).loan
      .amortization_schedule.periodic_payment.amount
  end

  test "payment schedule has correct number of payments" do
    assert_equal 360, mortgage.loan.amortization_schedule.payments.length
  end

  test "the first row opens on the principal and splits principal and interest" do
    first = mortgage.loan.amortization_rows.first

    assert_equal 1, first[:payment_number]
    assert_equal BigDecimal("500000"), first[:beginning_balance]
    assert_operator first[:interest_payment], :>, 0
    assert_operator first[:principal_payment], :>, 0
  end

  # C14
  test "final payment clears balance" do
    assert_equal BigDecimal("0"), mortgage.loan.amortization_schedule.payments.last.ending_balance.amount
  end

  test "each row's payment is its principal plus its interest" do
    mortgage.loan.amortization_rows.each do |row|
      assert_equal row[:principal_payment] + row[:interest_payment], row[:payment_amount]
    end
  end

  test "ending balance decreases monotonically" do
    mortgage.loan.amortization_schedule.payments.map(&:ending_balance).each_cons(2) do |previous, current|
      assert_operator current, :<=, previous
    end
  end

  test "each row opens on the balance the previous row closed on" do
    mortgage.loan.amortization_rows.each_cons(2) do |current, following|
      assert_equal current[:ending_balance], following[:beginning_balance]
    end
  end

  test "payment_for finds a payment by its date and nothing outside the schedule" do
    schedule = mortgage.loan.amortization_schedule

    assert_equal 1, schedule.payment_for(schedule.payments.first.date).number
    assert_nil schedule.payment_for(Date.new(2100, 1, 1))
  end

  test "a loan's total cost is principal plus total interest when it carries no premium" do
    loan = mortgage.loan

    assert_equal loan.original_balance + loan.amortization_schedule.total_interest, loan.total_cost
  end

  test "small loans and whole-unit currencies schedule" do
    small = mortgage(balance: 1_000, interest_rate: 5.0, term_months: 12).loan.amortization_schedule
    assert_equal 12, small.payments.length
    assert_equal BigDecimal("0"), small.payments.last.ending_balance.amount

    jpy = mortgage(balance: 5_000_000, currency: "JPY").loan.amortization_schedule
    assert_equal 360, jpy.payments.length
  end

  test "a very low rate still sizes a positive repayment under the straight-line figure" do
    payment = mortgage(balance: 100_000, interest_rate: 0.5, term_months: 120).loan.amortization_schedule.periodic_payment

    assert payment.positive?
    assert payment < Money.new(1000, "USD")
  end

  test "characterization golden master covers fixed-rate rows" do
    assert_characterized_schedule accounts(:characterization_fixed).loan, [
      characterized_row(1, "2024-02-15", "12.0", "340.02", "329.83", "10.19", "1000.00", "670.17"),
      characterized_row(2, "2024-03-15", "12.0", "340.02", "333.63", "6.39", "670.17", "336.54"),
      characterized_row(3, "2024-04-15", "12.0", "339.97", "336.54", "3.43", "336.54", "0.00")
    ]
  end

  test "characterization golden master covers variable rate rows with two changes" do
    assert_characterized_schedule accounts(:characterization_variable).loan, [
      characterized_row(1, "2024-02-01", "0.0", "333.33", "333.33", "0.00", "1000.00", "666.67"),
      # Row 2's period ran entirely at 0% and its row says so: since #184's
      # core swap a row carries the rate its period OPENED on (upstream's
      # row), where the fork's carried the 12% its payment was sized at. The
      # figures are the fork's: the rate effective 2024-03-01 is charged from
      # [03-01, 04-01) -- row 3 -- and sizes row 2's payment (C7/C8/C10, #48).
      #
      # Row 2's resize is sized from the interest that period actually charged
      # (#184's straddle fix, upstream's first_period_interest): 0.00 at 0%,
      # then a level 12% annuity for the one payment after it,
      # a = (1.01 - 1) / (0.01 x 1.01) = 0.990099, so
      # (666.67 + 0.00) / (1 + 0.990099) = 334.99. Row 3 then charges March's
      # 31 days at 12% on 331.68 = 3.38 and settles 335.06.
      characterized_row(2, "2024-03-01", "0.0", "334.99", "334.99", "0.00", "666.67", "331.68"),
      characterized_row(3, "2024-04-01", "12.0", "335.06", "331.68", "3.38", "331.68", "0.00")
    ]
  end

  test "characterization golden master covers zero-interest final settlement" do
    assert_characterized_schedule accounts(:characterization_zero_interest).loan, [
      characterized_row(1, "2024-02-01", "0.0", "33.33", "33.33", "0.00", "100.00", "66.67"),
      characterized_row(2, "2024-03-01", "0.0", "33.33", "33.33", "0.00", "66.67", "33.34"),
      characterized_row(3, "2024-04-01", "0.0", "33.34", "33.34", "0.00", "33.34", "0.00")
    ]
  end

  test "characterization golden master covers a short one-period loan" do
    assert_characterized_schedule accounts(:characterization_short).loan, [
      characterized_row(1, "2024-02-15", "12.0", "1010.19", "1000.00", "10.19", "1000.00", "0.00")
    ]
  end

  # Upstream's calendar (#184): 31 January -> 29 February -> 31 March ->
  # 30 April. The fork's stayed on the 29th.
  test "characterization golden master covers month-end clamping" do
    assert_characterized_schedule accounts(:characterization_month_end).loan, [
      characterized_row(1, "2024-02-29", "0.0", "33.33", "33.33", "0.00", "100.00", "66.67"),
      characterized_row(2, "2024-03-31", "0.0", "33.33", "33.33", "0.00", "66.67", "33.34"),
      characterized_row(3, "2024-04-30", "0.0", "33.34", "33.34", "0.00", "33.34", "0.00")
    ]
  end

  # The cached rows record the version of the calculation that produced them,
  # and that version is baked into the signature: it has to move with the
  # figures (#36), and the core swap moved them (dates for anchors on the
  # 29th-31st, the meaning of a row's interest_rate).
  test "the cache version names the upstream engine the rows now come from" do
    assert_equal 5, LoanAmortization::ALGORITHM_VERSION
  end

  test "the loan's schedule is not upstream's monthly one, and it is the one production persists" do
    loan = accounts(:characterization_fixed).loan

    monthly = Loan::AmortizationSchedule.for(loan, interest_for: nil)

    assert_not_equal monthly.total_interest, loan.amortization_schedule.total_interest,
      "if these agree the hook is not doing anything and this test proves nothing"
    loan.rebuild_amortization_schedule
    assert_equal loan.amortization_schedule.total_interest.amount, loan.amortizations.sum(:interest_payment)
  end

  test "a loan that cannot be scheduled has no rows" do
    loan = accounts(:characterization_fixed).loan
    loan.update!(term_months: nil)

    assert_nil loan.amortization_schedule
    assert_empty loan.amortization_rows
  end

  # #8's gate: the golden masters must fail on a deliberate one-cent change in
  # the per-period math both the schedule and the projection share, and pass
  # again once it is removed.
  test "the golden masters fail when the engine's per-period math moves by one cent" do
    loan = accounts(:characterization_fixed).loan
    rows = [
      characterized_row(1, "2024-02-15", "12.0", "340.02", "329.83", "10.19", "1000.00", "670.17"),
      characterized_row(2, "2024-03-15", "12.0", "340.02", "333.63", "6.39", "670.17", "336.54"),
      characterized_row(3, "2024-04-15", "12.0", "339.97", "336.54", "3.43", "336.54", "0.00")
    ]

    assert_characterized_schedule loan, rows

    with_one_cent_mutation do
      error = assert_raises(Minitest::Assertion) do
        assert_equal rows, uncached_schedule_rows(loan)
      end
      assert_match(/interest_payment/, error.message,
        "the failure must name the field that moved, not merely that something differs")
    end

    # Bypasses the memoised schedule, or this would re-read what the first
    # call cached and pass without running the restored method.
    assert_equal rows, uncached_schedule_rows(loan)
  end

  private
    def build_schedule(principal: 500_000, annual_rate: 3.5, term_months: 360,
                       start_date: Date.new(2026, 1, 1), currency: "USD")
      Loan::AmortizationSchedule.new(
        principal: principal,
        annual_rate: annual_rate,
        term_months: term_months,
        start_date: start_date,
        currency: currency
      )
    end

    def loan_account(**loan_attrs)
      Account.create! \
        family: families(:dylan_family),
        name: "Mortgage Loan",
        balance: 500_000,
        currency: "USD",
        accountable: Loan.create!(subtype: "mortgage", **loan_attrs)
    end

    def mortgage(balance: 500_000, currency: "USD", **loan_attrs)
      Account.create!(
        family: families(:dylan_family), name: "Test Mortgage #{SecureRandom.hex(3)}", balance: balance, currency: currency,
        accountable: Loan.create!({ subtype: "mortgage", interest_rate: 3.5, term_months: 360, rate_type: "fixed" }.merge(loan_attrs))
      )
    end

    def marker_loan
      mortgage(rate_type: "variable", term_months: 12, start_date: Date.new(2023, 1, 1)).loan
    end

    def characterized_row(number, date, rate, payment, principal, interest, beginning, ending)
      {
        payment_number: number,
        payment_date: Date.iso8601(date),
        interest_rate: BigDecimal(rate),
        payment_amount: BigDecimal(payment),
        principal_payment: BigDecimal(principal),
        interest_payment: BigDecimal(interest),
        beginning_balance: BigDecimal(beginning),
        ending_balance: BigDecimal(ending)
      }
    end

    # Adds a cent to every period's interest, through the module both the
    # schedule and the projection share. Restored unconditionally.
    def with_one_cent_mutation
      original = Loan::AmortizationMath.method(:step)
      Loan::AmortizationMath.singleton_class.send(:define_method, :step) do |**kwargs|
        row = original.call(**kwargs)
        row.merge(interest_payment: row[:interest_payment] + BigDecimal("0.01"))
      end
      yield
    ensure
      Loan::AmortizationMath.singleton_class.send(:define_method, :step, original)
    end

    # A fresh Loan instance, so neither the loan's memoised schedule nor the
    # schedule's memoised payments can hide a mutation applied after a read.
    def uncached_schedule_rows(loan)
      Loan.find(loan.id).amortization_rows
    end

    def assert_characterized_schedule(loan, expected_rows)
      actual_rows = loan.amortization_rows

      assert_equal expected_rows, actual_rows
      actual_rows.each_cons(2) do |current, following|
        assert_equal current[:ending_balance], following[:beginning_balance]
      end
      assert_equal BigDecimal("0"), actual_rows.last[:ending_balance]
    end
end
