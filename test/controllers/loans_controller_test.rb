require "test_helper"

class LoansControllerTest < ActionDispatch::IntegrationTest
  include AccountableResourceInterfaceTest

  setup do
    sign_in @user = users(:family_admin)
    @account = accounts(:loan)
  end

  test "creates with loan details" do
    assert_difference -> { Account.count } => 1,
      -> { Loan.count } => 1,
      -> { Valuation.count } => 1,
      -> { Entry.count } => 1 do
      post loans_path, params: {
        account: {
          name: "New Loan",
          balance: 50000,
          currency: "USD",
          institution_name: "Local Bank",
          institution_domain: "localbank.example",
          notes: "Mortgage notes",
          accountable_type: "Loan",
          accountable_attributes: {
            subtype: "mortgage",
            interest_rate: 5.5,
            term_months: 60,
            rate_type: "fixed",
            initial_balance: 50000
          }
        }
      }
    end

    created_account = Account.order(:created_at).last

    assert_equal "New Loan", created_account.name
    assert_equal 50000, created_account.balance
    assert_equal "USD", created_account.currency
    assert_equal "Local Bank", created_account[:institution_name]
    assert_equal "localbank.example", created_account[:institution_domain]
    assert_equal "Mortgage notes", created_account[:notes]
    assert_equal "mortgage", created_account.accountable.subtype
    assert_equal 5.5, created_account.accountable.interest_rate
    assert_equal 60, created_account.accountable.term_months
    assert_equal "fixed", created_account.accountable.rate_type
    assert_equal 50000, created_account.accountable.initial_balance

    assert_redirected_to created_account
    assert_equal "Loan account created", flash[:notice]
    assert_enqueued_with(job: SyncJob)
  end

  test "updates with loan details" do
    assert_no_difference [ "Account.count", "Loan.count" ] do
      patch loan_path(@account), params: {
        account: {
          name: "Updated Loan",
          balance: 45000,
          currency: "USD",
          institution_name: "Updated Bank",
          institution_domain: "updatedbank.example",
          notes: "Updated loan notes",
          accountable_type: "Loan",
          accountable_attributes: {
            id: @account.accountable_id,
            subtype: "auto",
            interest_rate: 4.5,
            term_months: 48,
            rate_type: "fixed",
            initial_balance: 48000
          }
        }
      }
    end

    @account.reload

    assert_equal "Updated Loan", @account.name
    assert_equal 45000, @account.balance
    assert_equal "Updated Bank", @account[:institution_name]
    assert_equal "updatedbank.example", @account[:institution_domain]
    assert_equal "Updated loan notes", @account[:notes]
    assert_equal "auto", @account.accountable.subtype
    assert_equal 4.5, @account.accountable.interest_rate
    assert_equal 48, @account.accountable.term_months
    assert_equal "fixed", @account.accountable.rate_type
    assert_equal 48000, @account.accountable.initial_balance

    assert_redirected_to @account
    assert_equal "Loan account updated", flash[:notice]
    assert_enqueued_with(job: SyncJob)
  end

  test "renders the amortization schedule tab for a fixed rate loan" do
    get account_path(@account, tab: "schedule")

    assert_response :success
    # The chart card above the tabs carries its own data table (#100), so the
    # count is scoped to the schedule's table.
    chart_table = ActionView::RecordIdentifier.dom_id(@account, :loan_chart_table)
    assert_select "table:not(##{chart_table}) tbody tr", count: @account.loan.term_months
    assert_match "Total Interest", response.body
  end

  # A variable loan IS amortizable since #104, and a provider's own rate type
  # reads as variable since #100 decision 8, so the unamortizable case is now
  # a loan with no rate type at all.
  test "hides the schedule tab when the loan cannot be amortized" do
    @account.loan.update!(rate_type: "")

    get account_path(@account, tab: "schedule")

    assert_response :success
    assert_select "table tbody tr", count: 0
  end

  test "records rate changes and an origination date submitted through the form" do
    patch loan_path(@account), params: {
      account: {
        accountable_attributes: {
          id: @account.loan.id,
          rate_type: "variable",
          start_date: "2024-03-15",
          rate_changes: [
            { effective_date: "2026-04-01", rate: "7.25" },
            { effective_date: "2026-10-01", rate: "6.5" },
            { effective_date: "", rate: "" }
          ]
        }
      }
    }

    @account.loan.reload
    assert_equal({ "2026-04-01" => "7.25", "2026-10-01" => "6.5" }, @account.loan.variable_rate_schedule,
      "the wholly blank sentinel row must be dropped rather than persisted or raising")
    assert_equal Date.new(2024, 3, 15), @account.loan.start_date
    assert_equal Date.new(2024, 3, 15), @account.loan.origination_date
  end

  test "the schedule tab reflects a recorded rate change" do
    @account.loan.update!(rate_type: "variable", interest_rate: 6, term_months: 24)

    get account_path(@account, tab: "schedule")
    flat_body = response.body

    @account.loan.update!(variable_rate_schedule: { "2027-01-01" => "18.0" })
    get account_path(@account, tab: "schedule")

    assert_response :success
    assert_not_equal flat_body, response.body,
      "recording a rate change must change what the schedule tab renders"
    # A substring free of characters ERB escapes -- the full string contains an
    # apostrophe and renders as &#39;.
    assert_match "re-amortises at each recorded change", response.body
    assert_match I18n.t("loans.tabs.schedule.opening_payment"), response.body,
      "a re-amortising schedule must not label its first payment as THE monthly payment"
  end

  # A row with one half filled in is a typo, not a blank. Dropping it silently
  # loses what the user typed between submit and redisplay and never tells them
  # which row went.
  test "a half-filled rate change is rejected rather than silently dropped" do
    @account.loan.update!(rate_type: "variable")

    patch loan_path(@account), params: {
      account: { accountable_attributes: {
        id: @account.loan.id, rate_type: "variable",
        rate_changes: [ { effective_date: "", rate: "9" } ]
      } }
    }

    assert_empty @account.loan.reload.variable_rate_schedule
    loan = @account.loan
    loan.rate_changes = [ { effective_date: "", rate: "9" } ]
    assert_not loan.valid?
    assert_equal [ { effective_date: "", rate: "9" } ], loan.invalid_rate_changes
    assert_includes loan.rate_change_rows, { effective_date: "", rate: "9" },
      "the typed row comes back so the form can redisplay it"
  end

  # Removing every row must clear the schedule. Without the form's blank
  # sentinel the PATCH carries no rate_changes key at all, nested assignment
  # never calls the writer, and the removed rows stay persisted.
  test "submitting only the blank sentinel clears the schedule" do
    @account.loan.update!(rate_type: "variable", variable_rate_schedule: { "2026-04-01" => "7.25" })

    patch loan_path(@account), params: {
      account: { accountable_attributes: {
        id: @account.loan.id, rate_type: "variable", rate_changes: [ { effective_date: "", rate: "" } ]
      } }
    }

    assert_empty @account.loan.reload.variable_rate_schedule
  end

  # Reads the payload off the mounted controller's own data attribute rather
  # than parsing rendered SVG paths, which would be a brittle way to assert on
  # data that already has model-level coverage. This test's job is to prove the
  # right payload reaches the browser and mounts the controller.
  def chart_payload
    node = css_select("[data-controller='loan-payoff-chart']").first
    node && JSON.parse(node["data-loan-payoff-chart-data-value"])
  end

  # #100: the chart lives at the top of the account page, inside the chart
  # card's Turbo frame, on whichever tab is open. The Schedule tab keeps its
  # table and cards and no longer carries a chart of its own.
  test "the account page mounts the loan balance chart with its three series" do
    get account_path(@account)

    assert_response :success
    payload = chart_payload
    assert payload["scheduled"].length > 1
    assert payload["projected"].length > 1
    assert_equal %w[actual scheduled projected] & payload["visible"], payload["visible"]
    assert_select "turbo-frame##{ActionView::RecordIdentifier.dom_id(@account, :chart_details)} [data-controller='loan-payoff-chart']", count: 1
    assert_select "turbo-frame##{ActionView::RecordIdentifier.dom_id(@account, :chart_details)} table", count: 1
  end

  test "the schedule tab renders its table without a chart of its own" do
    get account_path(@account, tab: "schedule")

    assert_response :success
    assert_select "[data-controller='loan-payoff-chart']", { count: 1 }, "one chart on the page, in the chart card"
    assert_select "table", { minimum: 2 }, "the schedule table and the chart's data table"
  end

  # A stray what-if parameter from an old link must change nothing: the
  # feature is not in this tranche (#100 decision 10).
  test "an extra-payment parameter is ignored" do
    get account_path(@account)
    baseline = chart_payload
    get account_path(@account, extra_payment: { amount: "2000", frequency: "monthly" })

    assert_response :success
    assert_equal baseline, chart_payload
  end

  test "a loan with no schedule renders the page without a loan chart" do
    @account.loan.update!(rate_type: "")

    get account_path(@account)

    assert_response :success
    assert_nil chart_payload
    assert_select "[data-controller='time-series-chart']", count: 1
  end
  # The helper takes an account and memoized into a single slot regardless of
  # it, so the second loan rendered in one request would have been handed the
  # first one's chart. Unreachable through the Schedule tab, which renders one
  # account -- and a helper_method any view can call is not a place to leave a
  # latent wrong-account bug.
  test "the payoff chart memo is keyed by the account it was asked about" do
    other = Account.create!(
      family: @account.family, name: "Second Loan", balance: 120_000, currency: "USD",
      accountable: Loan.new(subtype: "auto", interest_rate: 9, term_months: 60,
                            rate_type: "fixed", start_date: Date.new(2026, 6, 1))
    )

    controller = AccountsController.new
    controller.params = ActionController::Parameters.new

    first = controller.loan_payoff_chart(@account)
    second = controller.loan_payoff_chart(other)

    assert_not_equal first[:scheduled], second[:scheduled],
      "the second account was handed the first account's chart"
    assert_equal first, controller.loan_payoff_chart(@account),
      "and the first is still memoized rather than re-simulated"
  end
end
