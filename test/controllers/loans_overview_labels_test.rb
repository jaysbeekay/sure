require "test_helper"

# The Overview tab's cards, and the one figure among them that was wrong.
class LoansOverviewLabelsTest < ActionDispatch::IntegrationTest
  setup do
    sign_in users(:family_admin)
    @account = accounts(:loan)
  end

  # Rails renders a missing translation as the HUMANIZED KEY -- a missing
  # `current_interest_rate` comes out as "Current Interest Rate", which is
  # exactly the string these tests look for. Asserting on the text alone
  # therefore passes just as happily when the key does not exist at all.
  # Every label assertion goes through here.
  # Scoped to the key under test, deliberately: the account page carries one
  # pre-existing missing translation of its own
  # (`ui.account.activity_feed.toggle_selection_checkboxes`), and a page-wide
  # check would fail on someone else's gap.
  def assert_label(key, body)
    assert_no_match(/translation missing: en\.#{Regexp.escape(key)}/, body,
      "#{key} is missing -- Rails renders it as the humanized key, which is the very string being asserted")
    assert_match I18n.t(key), body
  end

  # #96 -- the card and the form field that sets it now name the same quantity
  # the same way.
  test "the opening balance card is labelled Original Loan Balance" do
    get account_path(@account, tab: "overview")

    assert_response :success
    assert_label "loans.tabs.overview.original_loan_balance", response.body
    assert_equal "Original Loan Balance", I18n.t("loans.tabs.overview.original_loan_balance")
    assert_no_match(/Original Principal/, response.body)
  end

  # #97 -- the figure is current_minimum_payment, re-amortised at today's rate.
  # Both tabs show it, so both must name it the same way; renaming one key and
  # not the other is the specific way this goes half-done.
  test "both tabs label the repayment Current Monthly Payment" do
    get account_path(@account, tab: "overview")
    assert_response :success
    assert_label "loans.tabs.overview.current_monthly_payment", response.body

    get account_path(@account, tab: "schedule")
    assert_response :success
    assert_label "loans.tabs.schedule.current_monthly_payment", response.body
    assert_no_match(/>\s*Monthly Payment\s*</, response.body,
      "the Schedule tab must not still say plain 'Monthly Payment'")
  end

  # #98 -- THE bug. The card read `loans.interest_rate`, the origination rate,
  # while the caption on the card beside it read the current one. Two answers
  # on one screen.
  test "a variable loan shows the current rate, matching the caption beside it" do
    loan = @account.loan
    loan.update!(rate_type: "variable", interest_rate: 6,
                 variable_rate_schedule: { 3.months.ago.to_date.iso8601 => "9.75" })

    get account_path(@account, tab: "overview")

    assert_response :success
    assert_label "loans.tabs.overview.current_interest_rate", response.body
    assert_match "9.750%", response.body, "the card must quote the rate in force today"
    assert_no_match(/6\.000%/, response.body,
      "the origination rate must not appear once a later change is in force")
  end

  # The safety property: nothing moves for the loans this card already served.
  test "a fixed loan's displayed rate is unchanged" do
    @account.loan.update!(rate_type: "fixed", interest_rate: 3.5)

    get account_path(@account, tab: "overview")

    assert_response :success
    assert_match "3.500%", response.body
  end

  # `variable_rate_schedule` is RETAINED when a loan is switched to fixed, so
  # switching back does not lose the rows. A fixed loan can therefore hold a
  # schedule that no longer applies -- and this card must show its fixed rate,
  # not the last variable one recorded. Every other caller of
  # current_variable_rate guarded on rate type externally, so nothing had ever
  # reached this path before.
  test "a fixed loan with a retained rate schedule still shows its fixed rate" do
    @account.loan.update!(rate_type: "variable", interest_rate: 3.5,
                          variable_rate_schedule: { 2.months.ago.to_date.iso8601 => "11.25" })
    @account.loan.update!(rate_type: "fixed")

    retained = @account.loan.reload.variable_rate_schedule
    assert_equal [ 2.months.ago.to_date.iso8601 ], retained.keys,
      "premise: the schedule is retained, not cleared, on the switch to fixed"
    assert_equal BigDecimal("11.25"), BigDecimal(retained.values.first.to_s)

    get account_path(@account, tab: "overview")

    assert_response :success
    assert_match "3.500%", response.body
    assert_no_match(/11\.250%/, response.body,
      "a fixed loan must not display a variable rate it no longer runs on")
  end

  # interest_rate is nullable and current_variable_rate falls back to it, so the
  # rate-less case must still render rather than printing a bare percent sign.
  test "a loan with no rate still shows Unknown" do
    @account.loan.update!(rate_type: "fixed", interest_rate: nil)

    get account_path(@account, tab: "overview")

    assert_response :success
    assert_match I18n.t("loans.tabs.overview.unknown"), response.body
  end
end
