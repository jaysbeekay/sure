require "test_helper"

class UI::Loan::RateChangeTableTest < ViewComponent::TestCase
  setup do
    @family = families(:dylan_family)
    @loan = variable_loan
  end

  test "renders one row per future rate change, in lender-letter shape" do
    @loan.add_variable_rate_change(Date.current + 2.months, 5.93)

    render_inline UI::Loan::RateChangeTable.new(loan: @loan)

    assert_selector "[data-rate-change-table] tr", count: 1
    assert_text I18n.t("UI.loan.rate_change_table.title")
  end

  # A change already in effect IS the current rate -- the card above this table
  # already states it, and repeating it as forthcoming would be wrong.
  test "a rate change already in effect is not listed as forthcoming" do
    @loan.add_variable_rate_change(Date.current - 2.months, 5.93)

    component = UI::Loan::RateChangeTable.new(loan: @loan)

    assert_empty component.rows
    assert_not component.render?
  end

  # cubic, #86: the schedule tab used to render this component without `as_of`,
  # so it took its own `Date.current` while the summary cards above it shared a
  # captured one. A render crossing midnight on an effective date could then
  # show a change here that the card above already treated as current.
  #
  # This asserts the injected date is actually load-bearing rather than
  # decorative -- the same change is forthcoming on one date and already in
  # effect on the next, so a component that ignored `as_of` would fail here.
  test "an injected as_of decides what counts as forthcoming" do
    effective_on = Date.current + 2.months
    @loan.add_variable_rate_change(effective_on, 5.93)

    day_before = UI::Loan::RateChangeTable.new(loan: @loan, as_of: effective_on - 1.day)
    assert_equal 1, day_before.rows.length,
      "a change effective tomorrow is still forthcoming"

    on_the_day = UI::Loan::RateChangeTable.new(loan: @loan.reload, as_of: effective_on)
    assert_empty on_the_day.rows,
      "once the effective date arrives the change IS the current rate, not news"
  end

  test "a variable loan with no scheduled changes renders nothing at all" do
    assert_not UI::Loan::RateChangeTable.new(loan: @loan).render?

    render_inline UI::Loan::RateChangeTable.new(loan: @loan)

    assert_no_text I18n.t("UI.loan.rate_change_table.title")
  end

  # #392: a change's "new repayment" is the contracted schedule's payment at
  # the first payment on or after its effective date, on the scheduled balance.
  # The current column is the card's figure, which is the schedule's payment in
  # force, so both columns sit on the schedule.
  test "a future change's new repayment is the schedule row at that date" do
    effective_on = Date.current + 2.months
    @loan.add_variable_rate_change(effective_on, 5.93)
    @loan.reload

    row = UI::Loan::RateChangeTable.new(loan: @loan).rows.sole
    schedule_row = @loan.amortization_schedule.payments.find { |p| p[:payment_date] >= effective_on }

    assert_equal Money.new(schedule_row[:payment_amount], "USD"), row[:new_payment]
    assert_equal Money.new(schedule_row[:beginning_balance], "USD"), row[:balance]
    assert_equal @loan.current_minimum_payment, row[:current_payment],
      "the current column is the card's figure"
    assert row[:new_payment] < row[:current_payment], "a rate cut must lower the quoted repayment"
  end

  # The base moved off the actual balance: neither an offset nor paying ahead
  # changes what the lender's letter quotes.
  test "an offset and a lower actual balance change neither column" do
    @loan.add_variable_rate_change(Date.current + 2.months, 5.93)
    before = UI::Loan::RateChangeTable.new(loan: @loan.reload).rows.sole

    offset = @family.accounts.create!(
      name: "Table Offset", balance: 50_000, currency: "USD", accountable: Depository.new
    )
    @loan.update!(offset_account_ids: [ offset.id ])
    @loan.account.update!(balance: @loan.account.balance - 20_000)
    after = UI::Loan::RateChangeTable.new(loan: @loan.reload).rows.sole

    assert_operator @loan.interest_bearing_balance.amount, :<, @loan.account.balance, "precondition: the offset counts"
    assert_equal before, after
  end

  # A change effective ON a payment date resizes that payment (C8), so its row
  # is that payment's own, not the next one.
  test "a change effective on a payment date is quoted from that payment's row" do
    payment_date = @loan.amortization_schedule.payments.map { |p| p[:payment_date] }.find { |d| d > Date.current + 3.months }
    @loan.add_variable_rate_change(payment_date, 5.93)
    @loan.reload

    row = UI::Loan::RateChangeTable.new(loan: @loan).rows.sole
    payments = @loan.amortization_schedule.payments
    on_date = payments.find { |p| p[:payment_date] == payment_date }
    before = payments[payments.index(on_date) - 1]

    assert_not_equal before[:payment_amount], on_date[:payment_amount],
      "precondition: the change resizes the payment on its date"
    assert_equal on_date[:payment_amount], row[:new_payment].amount
  end

  test "a fixed-rate loan carrying leftover rate rows renders nothing" do
    @loan.add_variable_rate_change(Date.current + 2.months, 5.93)
    @loan.update!(rate_type: "fixed")

    component = UI::Loan::RateChangeTable.new(loan: @loan.reload)

    assert_empty component.rows,
      "rate rows kept as history on a fixed loan are not forthcoming changes"
    assert_not component.render?
  end

  # #78 made "adjustable" mean variable. This table guarded on
  # `rate_type == "variable"`, so an adjustable loan silently rendered nothing
  # -- the exact defect #78 removed everywhere else.
  test "an adjustable-rate loan gets the table too" do
    @loan.update!(rate_type: "adjustable")
    @loan.reload.add_variable_rate_change(Date.current + 2.months, 5.93)

    component = UI::Loan::RateChangeTable.new(loan: @loan.reload)

    assert_equal 1, component.rows.length
    assert component.render?
  end

  # CodeRabbit, #79. The payoff card's projection HOLDS today's repayment, so a
  # large enough rate rise leaves it no longer covering the interest, the
  # simulation never converges, `applicable?` goes false and this table rendered
  # NOTHING -- precisely the case a borrower opens it for. On this fixture the
  # cliff was between 7.00% and 7.50%.
  test "a rate rise steep enough to break a held repayment still renders" do
    @loan.add_variable_rate_change(Date.current + 3.months, 9.00)

    component = UI::Loan::RateChangeTable.new(loan: @loan.reload)
    row = component.rows.sole

    assert component.render?
    assert row[:new_payment] > row[:current_payment],
      "a rate rise must raise the quoted repayment"
    assert_not Loan::PayoffProjection.new(@loan).applicable?,
      "the fixture must actually break the HELD projection, or this proves nothing"
  end

  # The balances the table quotes off must be produced by the very repayment it
  # quotes. Under the held projection the trajectory assumed the borrower kept
  # paying today's amount through every future change, so the second and later
  # rows were read off a balance that could not occur.
  test "later rows are quoted off balances the earlier re-amortisation produces" do
    @loan.add_variable_rate_change(Date.current + 3.months, 7.50)
    @loan.reload.add_variable_rate_change(Date.current + 15.months, 8.50)

    rows = UI::Loan::RateChangeTable.new(loan: @loan.reload).rows

    assert_equal 2, rows.length
    assert rows[1][:balance] < rows[0][:balance],
      "the balance must fall between the two changes"
    assert rows[1][:new_payment] > rows[0][:new_payment],
      "the second, higher rate must quote a higher repayment than the first"
  end

  # CodeRabbit, #79. `unamortizable_payment?` judges the CONTRACTED repayment,
  # which is not the one a re-amortising projection uses. Left applying to
  # :reamortize it blanked this table for a loan whose rate has ALREADY risen
  # past what its old repayment services -- the loan most in need of it.
  test "a loan whose old repayment no longer covers interest still gets the table" do
    @loan.update!(interest_rate: 1.0)
    @loan.reload.add_variable_rate_change(Date.current - 1.month, 12.0)
    @loan.reload.add_variable_rate_change(Date.current + 6.months, 13.0)

    component = UI::Loan::RateChangeTable.new(loan: @loan.reload)

    assert_not Loan::PayoffProjection.new(@loan).applicable?,
      "the fixture must actually defeat the held projection, or this proves nothing"
    assert_equal 1, component.rows.length,
      "the already-effective rise is the current rate, so only the future one is listed"
    assert component.render?
  end

  private

    # With an opening valuation, as a real loan has, so `original_balance` --
    # and with it the schedule -- does not move when the balance does.
    def variable_loan
      start_date = Date.current - 83.months
      account = @family.accounts.create!(
        name: "Rate Change Table Loan",
        balance: 400_762.12,
        currency: "USD",
        accountable: Loan.new(
          rate_type: "variable", interest_rate: 6.18, term_months: 360,
          initial_balance: 400_762.12, start_date: start_date
        )
      )
      account.entries.create!(
        name: "Opening", amount: 400_762.12, currency: "USD", date: start_date,
        entryable: Valuation.new(kind: "opening_anchor")
      )
      account.loan.reload
    end
end
