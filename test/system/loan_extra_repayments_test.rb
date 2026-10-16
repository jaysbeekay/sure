require "application_system_test_case"

class LoanExtraRepaymentsTest < ApplicationSystemTestCase
  setup do
    sign_in @user = users(:family_admin)
  end

  # #469: `.form-field` is full width, so on its own the amount field took the
  # whole row and Apply wrapped below it. At the default desktop viewport the
  # button must sit beside the field: its vertical span overlaps the field's.
  test "the extra repayment amount and Apply share one row" do
    visit account_path(on_schedule_loan_account, tab: "extra_repayments")

    field = find("input[name='extra_payment[amount]']").ancestor(".form-field")
    button = find("button[type='submit']", text: I18n.t("loans.tabs.extra_repayments.apply"))

    field_box = bounding_box(field)
    button_box = bounding_box(button)

    assert_operator button_box["top"], :<, field_box["bottom"],
      "Apply starts below the field (#{button_box.inspect} vs #{field_box.inspect}), so it wrapped onto its own row"
    assert_operator button_box["left"], :>=, field_box["right"],
      "Apply should sit to the right of the field"
  end

  private
    def bounding_box(element)
      page.evaluate_script(<<~JS, element)
        (function(el) { const r = el.getBoundingClientRect(); return { top: r.top, bottom: r.bottom, left: r.left, right: r.right }; })(arguments[0])
      JS
    end

    def on_schedule_loan_account
      start_date = Date.current
      account = Account.create!(
        family: @user.family,
        name: "On-Schedule Loan",
        balance: 500000,
        currency: "USD",
        accountable: Loan.create!(subtype: "mortgage", interest_rate: 3.5, term_months: 360, rate_type: "fixed", start_date: start_date)
      )
      account.entries.create!(
        name: "Starting balance", amount: 500000, currency: "USD", date: start_date,
        entryable: Valuation.new(kind: "opening_anchor")
      )
      account
    end
end
