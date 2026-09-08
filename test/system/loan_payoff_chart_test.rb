require "application_system_test_case"

# The one thing the Ruby and controller-level tests cannot say.
#
# Loan::PayoffChartTest proves the payload is right, and the controller test
# proves it reaches the data attribute. Neither proves a line is PAINTED --
# which is the failure mode this chart has already been reported for once
# (#101: a projected payoff line that renders with correct geometry and no
# error, because its stroke never resolved to a colour).
#
# So these assertions are deliberately about the rendered SVG and nothing else:
# that each series exists as a path, that it has real geometry, and that its
# stroke resolved to something that will actually mark the screen. A test that
# re-checked payoff dates here would be re-running Loan::PayoffChartTest
# through a browser, slowly.
class LoanPayoffChartTest < ApplicationSystemTestCase
  # Pinned so the schedule, the projection and therefore the number of drawn
  # series are the same run to run. The loan opens 2026-01-01 over 24 months,
  # so this sits mid-term with real history behind it and real term ahead.
  TODAY = Date.new(2027, 1, 15)

  setup do
    sign_in @user = users(:family_admin)
  end

  test "the chart paints the scheduled and projected lines" do
    travel_to TODAY do
      account = on_contract_loan_account

      visit account_path(account, tab: "schedule")

      assert_selector "[data-controller='loan-payoff-chart'] svg"

      %w[scheduled projected].each do |key|
        path = find("[data-controller='loan-payoff-chart'] svg path[data-series='#{key}']")

        assert path["d"].to_s.start_with?("M"),
          "the #{key} line has no geometry"
        assert_not_equal "none", stroke_of(path),
          "the #{key} line has geometry but no resolved stroke, so it does not mark the screen -- #101 exactly"
      end

      # Nothing has been modelled, so there is nothing for a third line to say.
      assert_no_selector "[data-controller='loan-payoff-chart'] svg path[data-series='accelerated']"
    end
  end

  # The comparison the chart exists for: "where am I heading, and where would I
  # head if I paid more?". An earlier design had the hypothesis REPLACE the
  # projection, answering half the question by deleting the other half. This
  # asserts all three coexist in the DOM, not just in the payload.
  test "modelling an extra payment adds a third line without removing the second" do
    travel_to TODAY do
      account = on_contract_loan_account

      visit account_path(account, tab: "schedule")
      assert_selector "[data-controller='loan-payoff-chart'] svg path[data-series='projected']"

      fill_in "extra_payment_amount", with: "2000"
      click_on I18n.t("loans.tabs.schedule.extra_payment.apply")

      %w[scheduled projected accelerated].each do |key|
        path = find("[data-controller='loan-payoff-chart'] svg path[data-series='#{key}']")

        assert path["d"].to_s.start_with?("M"), "the #{key} line has no geometry"
        assert_not_equal "none", stroke_of(path), "the #{key} line does not mark the screen"
      end
    end
  end

  # Gate G6 asks for figures a screen reader can reach the same way the sighted
  # summary cards are reached, so the alternative is real DOM text and not only
  # the SVG's aria-label.
  test "the accessible description is real text in the document" do
    travel_to TODAY do
      account = on_contract_loan_account
      description = Loan::PayoffChart.new(account.loan, as_of: TODAY).payload[:aria_description]

      visit account_path(account, tab: "schedule")

      assert_selector "p.sr-only", text: description, visible: :all
      # Built as an attribute comparison rather than a CSS attribute selector:
      # the description carries apostrophes, which no amount of quoting makes
      # into a legal selector.
      assert_equal description,
        find("[data-controller='loan-payoff-chart'] svg")["aria-label"]
    end
  end

  private
    # `stroke: none` is the initial value, and it is what an unresolvable
    # colour leaves behind -- the whole point of reading the computed style
    # rather than the attribute we wrote.
    def stroke_of(path)
      page.evaluate_script(
        "getComputedStyle(document.querySelector(\"svg path[data-series='#{path['data-series']}']\")).stroke"
      )
    end

    def loan_account
      Account.create!(
        family: @user.family, name: "Payoff Chart Loan",
        balance: 500_000, currency: "USD",
        accountable: Loan.new(subtype: "mortgage", interest_rate: 6, term_months: 24,
                              rate_type: "fixed", start_date: Date.new(2026, 1, 1))
      )
    end

    # A borrower exactly on contract. The projection then has somewhere to go
    # and the accelerated line has something to beat; a loan whose balance has
    # run away has no payoff date at all, which is a different test.
    def on_contract_loan_account
      account = loan_account
      scheduled = account.loan.amortization_schedule.payments
        .select { |p| p.date <= TODAY }.last.ending_balance.amount
      account.update!(balance: scheduled)
      account.reload
      account
    end
end
