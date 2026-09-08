require "test_helper"

class Loan::PayoffChartTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @today = Date.new(2027, 1, 15)
  end

  test "carries the original schedule and the projection, and no third line by default" do
    loan = on_contract_loan
    payload = Loan::PayoffChart.new(loan, as_of: @today).payload

    assert payload[:scheduled].length > 1
    assert payload[:projected].length > 1
    assert_empty payload[:accelerated]
    assert_equal @today.iso8601, payload[:today]
    assert_equal "USD", payload[:currency]
  end

  # The comparison this chart exists for. An earlier design had the hypothesis
  # REPLACE the projection, which answers "where would I head if I paid more?"
  # by deleting "where am I heading?".
  test "all three series coexist when an extra payment is modelled" do
    loan = on_contract_loan
    payload = Loan::PayoffChart.new(
      loan, as_of: @today, extra_payment: { amount: 2_000, frequency: "monthly" }
    ).payload

    assert payload[:scheduled].length > 1
    assert payload[:projected].length > 1
    assert payload[:accelerated].length > 1
    assert_operator Date.parse(payload[:accelerated_payoff_date]), :<,
      Date.parse(payload[:projected_payoff_date])
  end

  test "the original schedule spans origination to maturity, and the projections start today" do
    loan = on_contract_loan
    payload = Loan::PayoffChart.new(loan, as_of: @today).payload

    assert_operator Date.parse(payload[:scheduled].first[:date]), :<, @today,
      "the contract's own history is part of the line"
    assert_equal @today.iso8601, payload[:projected].first[:date],
      "a projection opens at today's real balance, not at its first payment"
  end

  test "a hypothesis that changes nothing draws no third line" do
    loan = on_contract_loan

    [ { amount: 0, frequency: "monthly" },
      { amount: 500, frequency: "fortnightly" },
      { amount: "banana", frequency: "monthly" } ].each do |bad|
      payload = Loan::PayoffChart.new(loan, as_of: @today, extra_payment: bad).payload

      assert_empty payload[:accelerated],
        "#{bad.inspect} degrades to the baseline, so a third line would assert a difference that is not there"
    end
  end

  test "no payload at all for a loan with no schedule" do
    loan = build_loan(rate_type: "teaser")

    assert_nil Loan::PayoffChart.new(loan, as_of: @today).payload
  end

  test "the accessible description names a balance and both payoff dates" do
    payload = Loan::PayoffChart.new(on_contract_loan, as_of: @today).payload

    assert_match(/\$/, payload[:aria_description])
    assert_match(/2028/, payload[:aria_description])
  end

  # A borrower too far behind has no payoff date. The description must say so
  # rather than interpolating a bare nil into a sentence.
  test "the description says so when the contract no longer pays the loan off" do
    loan = build_loan
    loan.account.update!(balance: 400_000)

    payload = Loan::PayoffChart.new(loan, as_of: @today).payload

    assert_nil payload[:projected_payoff_date]
    assert_match I18n.t("loans.tabs.schedule.chart.no_payoff"), payload[:aria_description]
  end

  private
    def build_loan(rate_type: "fixed")
      Account.create!(
        family: @family, name: "Loan #{SecureRandom.hex(4)}",
        balance: 500_000, currency: "USD",
        accountable: Loan.new(subtype: "mortgage", interest_rate: 6, term_months: 24,
                              rate_type: rate_type, start_date: Date.new(2026, 1, 1))
      ).loan
    end

    def on_contract_loan
      loan = build_loan
      scheduled = loan.amortization_schedule.payments
        .select { |p| p.date <= @today }.last.ending_balance.amount
      loan.account.update!(balance: scheduled)
      loan.reload
    end
end
