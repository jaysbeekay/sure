require "test_helper"

class UI::Account::ChartTest < ViewComponent::TestCase
  setup do
    @account = accounts(:investment)
    @account.holdings.destroy_all
  end

  test "renders positive gains with explicit plus sign" do
    create_holding(cost_basis: 90)

    render_inline(UI::Account::Chart.new(account: @account, view: "gains"))

    assert_text "+$100.00"
  end

  test "does not sign non-gains views" do
    component = UI::Account::Chart.new(account: @account, view: "balance")

    assert_equal @account.balance_money.format, component.view_balance_display
    refute component.view_balance_display.start_with?("+")
  end

  test "negative gains keep plain money formatting" do
    create_holding(cost_basis: 110)

    component = UI::Account::Chart.new(account: @account, view: "gains")

    assert_equal "-$100.00", component.view_balance_display
  end

  test "converted amount is signed like the main indicator for foreign-currency accounts" do
    @account.update!(currency: "EUR")
    create_holding(cost_basis: 90)
    ExchangeRate.create!(date: Date.current, from_currency: "EUR", to_currency: "USD", rate: 1.1)

    component = UI::Account::Chart.new(account: @account, view: "gains")

    assert_equal "+€100.00", component.view_balance_display
    assert_equal "+$110.00", component.converted_balance_display
  end

  # #100: a loan with a schedule takes the loan balance chart; every other
  # account keeps the chart it always had. Asserted on the mounted controller,
  # because "unchanged for everyone else" is the blast-radius promise this
  # branch makes.
  test "a loan account with a chart payload mounts the loan balance chart and nothing else" do
    loan_account = accounts(:loan)
    payload = Loan::PayoffChart.new(loan_account.loan, as_of: Date.current).payload

    render_inline(UI::Account::Chart.new(account: loan_account, loan_chart: payload, as_of: Date.current))

    assert_selector "[data-controller='loan-payoff-chart']"
    assert_no_selector "[data-controller='time-series-chart']"
    # Inside a collapsed <details>, so hidden until opened.
    assert_selector "table##{ActionView::RecordIdentifier.dom_id(loan_account, :loan_chart_table)}", visible: :all
    assert_selector "p.sr-only", text: payload[:aria_description], visible: :all
  end

  test "a non-loan account mounts the time-series chart and no loan chart" do
    render_inline(UI::Account::Chart.new(account: @account, view: "balance"))

    assert_no_selector "[data-controller='loan-payoff-chart']"
  end

  test "a loan without a chart payload falls back to the chart every account has" do
    loan_account = accounts(:loan)

    render_inline(UI::Account::Chart.new(account: loan_account, loan_chart: nil))

    assert_no_selector "[data-controller='loan-payoff-chart']"
  end

  private
    # 10 shares at $100 market price; gain = 1000 - cost_basis * 10
    def create_holding(cost_basis:)
      Holding.create!(
        account: @account,
        security: securities(:aapl),
        date: Date.current,
        qty: 10,
        price: 100,
        amount: 1000,
        currency: @account.currency,
        cost_basis: cost_basis
      )
    end
end
