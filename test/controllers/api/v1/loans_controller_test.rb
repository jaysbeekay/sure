require "test_helper"

class Api::V1::LoansControllerTest < ActionDispatch::IntegrationTest
  setup do
    @family = families(:dylan_family)
    @user = users(:family_admin)
    @api_key = ApiKey.create!(
      user: @user,
      name: "Loan API Test Key",
      scopes: [ "read" ],
      source: "web",
      key: ApiKey.generate_secure_key
    )

    @loan_account = create_loan_account(name: "Test Mortgage")
    @variable_loan_account = create_loan_account(name: "Variable Loan", subtype: "line_of_credit", rate_type: "variable")
    @non_amortizable_loan_account = create_loan_account(name: "No Rate Loan", subtype: "other", interest_rate: nil)
  end

  def api_headers(api_key = @api_key)
    { "X-Api-Key" => api_key.display_key }
  end

  test "returns amortization schedule for fixed rate loan" do
    loan = @loan_account.accountable
    get api_v1_loan_amortization_schedule_path(loan), headers: api_headers
    assert_response :success

    json = JSON.parse(response.body)
    schedule = loan.amortization_schedule
    assert_equal loan.id, json["loan"]["id"]
    assert_equal loan.account.id, json["loan"]["account_id"]
    assert_equal "current", json["schedule"]["status"]
    assert_equal schedule.periodic_payment.amount.to_s, json["schedule"]["monthly_payment"]
    assert_equal schedule.total_interest.amount.to_s, json["schedule"]["total_interest"]
    assert_equal (loan.original_balance.amount + schedule.total_interest.amount).to_s, json["schedule"]["total_cost"]
    assert_equal schedule.payoff_date.iso8601, json["schedule"]["payoff_date"]
    assert_equal schedule.payments.size, json["schedule"]["payment_count"]
    assert_equal false, json["schedule"]["has_rate_changes"]
    assert_kind_of String, json["payments"].first["payment_amount"]
    assert_kind_of String, json["payments"].first["principal_payment"]
    assert_kind_of String, json["payments"].first["interest_payment"]
    assert_kind_of String, json["payments"].first["interest_rate"]
    assert json.key?("payoff_projection")
  end

  test "each payment carries the schedule's figures and opens on the balance the last one closed on" do
    loan = @loan_account.accountable
    get api_v1_loan_amortization_schedule_path(loan), params: { page: 2, per_page: 3 }, headers: api_headers
    assert_response :success

    rows = JSON.parse(response.body)["payments"]
    payments = loan.amortization_schedule.payments
    assert_equal [ 4, 5, 6 ], rows.map { |row| row["payment_number"] }
    rows.each_with_index do |row, position|
      payment = payments[3 + position]
      assert_equal payment.date.iso8601, row["payment_date"]
      assert_equal payment.payment.amount.to_s, row["payment_amount"]
      assert_equal payment.principal.amount.to_s, row["principal_payment"]
      assert_equal payment.interest.amount.to_s, row["interest_payment"]
      assert_equal payment.ending_balance.amount.to_s, row["ending_balance"]
      assert_equal payments[2 + position].ending_balance.amount.to_s, row["beginning_balance"]
    end
  end

  test "the first payment opens on the loan's principal" do
    loan = @loan_account.accountable
    get api_v1_loan_amortization_schedule_path(loan), params: { per_page: 1 }, headers: api_headers
    assert_response :success

    row = JSON.parse(response.body)["payments"].first
    assert_equal loan.amortization_schedule.principal.to_s, row["beginning_balance"]
    assert_equal 1, row["payment_number"]
  end

  # The schedule hides its per-row rates, so this reads them from the run it
  # came from: a resolver asked about the wrong date would miss the row a change
  # first accrues on.
  test "each payment reports the rate that accrued over it, across a recorded rate change" do
    loan = @variable_loan_account.accountable
    loan.update!(start_date: 2.years.ago.to_date, rate_changes: [ { effective_date: 1.year.ago.to_date.iso8601, rate: "5.25" } ])

    get api_v1_loan_amortization_schedule_path(loan), params: { per_page: 36 }, headers: api_headers
    assert_response :success

    rows = JSON.parse(response.body)["payments"]
    expected = loan.reload.amortization_schedule.send(:simulation).payments.first(36).map { |row| row[:interest_rate].to_f }
    assert_equal expected, rows.map { |row| row["interest_rate"].to_f }
    assert_equal [ 3.5, 5.25 ], rows.map { |row| row["interest_rate"].to_f }.uniq
  end

  test "reports a variable loan's rate changes and the next one to come" do
    loan = @variable_loan_account.accountable
    upcoming = Date.current + 1.year
    loan.update!(start_date: 2.years.ago.to_date, rate_changes: [
      { effective_date: (Date.current - 1.year).iso8601, rate: "3.5" },
      { effective_date: upcoming.iso8601, rate: "4.0" }
    ])

    get api_v1_loan_amortization_schedule_path(loan), headers: api_headers
    assert_response :success

    json = JSON.parse(response.body)
    assert_equal true, json["schedule"]["has_rate_changes"]
    assert_equal upcoming.iso8601, json["loan"]["next_rate_change_date"]
  end

  test "a fixed loan has no next rate change" do
    get api_v1_loan_amortization_schedule_path(@loan_account.accountable), headers: api_headers
    assert_response :success

    assert_nil JSON.parse(response.body)["loan"]["next_rate_change_date"]
  end

  test "returns a payoff projection reflecting extra principal already paid" do
    loan_account = create_anchored_loan(start_date: Date.current)
    loan_account.update!(balance: 450000)

    get api_v1_loan_amortization_schedule_path(loan_account.accountable), headers: api_headers
    assert_response :success

    projection = JSON.parse(response.body)["payoff_projection"]
    assert projection.present?
    assert_equal "$450,000.00", projection["current_balance"]
    assert projection["months_saved"] > 0
    # A plain number a client can parse, signed, not a formatted amount.
    assert_match(/\A-?\d+(\.\d+)?\z/, projection["interest_saved"])
    assert projection["interest_saved"].to_d > 0
  end

  # Upstream's projection never runs past maturity, so a loan behind its
  # contract has no payoff date. The field is there and null, not an error.
  test "a loan behind its contract serialises with no projected payoff date" do
    loan_account = create_anchored_loan(start_date: 2.years.ago.to_date)
    schedule_balance = loan_account.loan.amortization_schedule.payments.reverse.find { |payment| payment.date <= Date.current }.ending_balance.amount
    loan_account.update!(balance: schedule_balance + 5_000)

    get api_v1_loan_amortization_schedule_path(loan_account.accountable), headers: api_headers
    assert_response :success

    projection = JSON.parse(response.body)["payoff_projection"]
    assert projection.present?, "the projection applies: the balance is positive and payments remain"
    assert projection.key?("projected_payoff_date")
    assert_nil projection["projected_payoff_date"]
    assert_kind_of String, projection["projected_total_interest"]
  end

  # Regression: the projection used to anchor on Date.current.next_month
  # (today's day-of-month) instead of the loan's real payment anchor day.
  # Covers the fix end-to-end through the API/serializer, not just the
  # model (see Loan::PayoffProjectionTest for the underlying calculation).
  test "payoff projection's payoff date reflects the loan's real payment anchor, not today's day-of-month" do
    # Pinned: if this ran on the 15th of any month, start_date's day-15
    # anchor would coincide with Date.current.next_month, defeating the
    # "real anchor mismatch" guard below and the point of the regression.
    travel_to Date.new(2026, 3, 20) do
      start_date = 2.years.ago.to_date.change(day: 15)
      loan_account = create_anchored_loan(start_date: start_date)
      loan_account.update!(balance: 450000)

      next_scheduled_date = loan_account.loan.amortization_schedule.payments.find { |payment| payment.date > Date.current }.date
      assert_not_equal Date.current.next_month, next_scheduled_date, "test setup should exercise a real anchor mismatch"
      expected_payoff_date = loan_account.loan.payoff_projection.payoff_date
      assert_not_nil expected_payoff_date

      get api_v1_loan_amortization_schedule_path(loan_account.accountable), headers: api_headers
      assert_response :success

      projection = JSON.parse(response.body)["payoff_projection"]
      assert_equal expected_payoff_date.iso8601, projection["projected_payoff_date"]
    end
  end

  test "returns a payoff projection for a variable rate loan" do
    loan = @variable_loan_account.accountable
    get api_v1_loan_amortization_schedule_path(loan), headers: api_headers
    assert_response :success

    json = JSON.parse(response.body)
    assert json.key?("payoff_projection"), "payoff_projection should be present as an explicit null, not absent"
    assert json["payoff_projection"].present?
    assert_equal "$500,000.00", json["payoff_projection"]["current_balance"]
  end

  test "returns paginated payments" do
    loan = @loan_account.accountable
    get api_v1_loan_amortization_schedule_path(loan),
        params: { page: 1, per_page: 10 },
        headers: api_headers
    assert_response :success

    json = JSON.parse(response.body)
    assert_equal 10, json["payments"].length
    assert_equal loan.amortization_schedule.payments.size, json["pagination"]["total_count"]
    assert_equal 0, json["pagination"]["offset"]
  end

  test "a page past the last payment is empty, not an error" do
    get api_v1_loan_amortization_schedule_path(@loan_account.accountable),
        params: { page: 50, per_page: 100 },
        headers: api_headers
    assert_response :success

    assert_equal [], JSON.parse(response.body)["payments"]
  end

  # Nothing is stored, so a loan whose terms just changed is answered from them
  # at once. There is no rebuild to wait for and no stale answer to serve.
  test "a change to the loan's terms shows in the next response" do
    loan = @loan_account.accountable
    get api_v1_loan_amortization_schedule_path(loan), headers: api_headers
    before = JSON.parse(response.body)["schedule"]["monthly_payment"]

    Loan.find(loan.id).update!(interest_rate: 5.0)

    get api_v1_loan_amortization_schedule_path(loan), headers: api_headers
    assert_response :success
    json = JSON.parse(response.body)
    assert_equal "current", json["schedule"]["status"]
    assert_not_equal before, json["schedule"]["monthly_payment"]
    assert_equal 5.0, json["payments"].first["interest_rate"].to_f
  end

  test "a read never writes to a loan's records or enqueues a job" do
    loan = @loan_account.accountable
    writes = capture_sql { assert_no_enqueued_jobs { get api_v1_loan_amortization_schedule_path(loan), headers: api_headers } }
      .grep(/\A\s*(INSERT|UPDATE|DELETE)/i)
      .grep(/"(loans|accounts|entries|valuations)"/)

    assert_response :success
    assert_empty writes
  end

  # The schedule is computed in memory, so a longer loan must cost arithmetic
  # and not queries.
  test "the number of queries does not grow with the length of the loan" do
    short = create_anchored_loan(start_date: 1.month.ago.to_date, term_months: 12)
    long = create_anchored_loan(start_date: 1.month.ago.to_date, term_months: 1200)

    short_queries = capture_sql { get api_v1_loan_amortization_schedule_path(short.accountable), headers: api_headers }
    assert_response :success
    long_queries = capture_sql { get api_v1_loan_amortization_schedule_path(long.accountable), headers: api_headers }
    assert_response :success

    assert_equal 1200, JSON.parse(response.body)["pagination"]["total_count"]
    assert_operator long_queries.size, :<=, short_queries.size + 2
  end

  test "gracefully rejects malformed pagination params instead of erroring" do
    loan = @loan_account.accountable
    get api_v1_loan_amortization_schedule_path(loan),
        params: { page: [ 1, 2 ], per_page: [ "x" ] },
        headers: api_headers
    assert_response :success

    json = JSON.parse(response.body)
    assert_equal 25, json["pagination"]["limit"]
    assert_equal 0, json["pagination"]["offset"]
  end

  test "bounds an excessively large page number" do
    loan = @loan_account.accountable
    get api_v1_loan_amortization_schedule_path(loan),
        params: { page: 2_000_000 },
        headers: api_headers

    assert_response :success
    json = JSON.parse(response.body)
    assert_equal (Api::V1::LoansController::MAX_PAGE - 1) * 25, json["pagination"]["offset"]
  end

  test "returns 404 for a malformed loan id instead of erroring" do
    get api_v1_loan_amortization_schedule_path("not-a-valid-uuid"),
        headers: api_headers
    assert_response :not_found
  end

  test "returns amortization schedule for variable rate loan using the flat rate" do
    loan = @variable_loan_account.accountable
    get api_v1_loan_amortization_schedule_path(loan), headers: api_headers
    assert_response :success

    json = JSON.parse(response.body)
    assert_equal "current", json["schedule"]["status"]
    assert json["payments"].present?
    assert_equal loan.interest_rate.to_f, json["payments"].first["interest_rate"].to_f
  end

  test "returns error for loan without an interest rate" do
    loan = @non_amortizable_loan_account.accountable
    get api_v1_loan_amortization_schedule_path(loan),
        headers: api_headers
    assert_response :unprocessable_entity

    json = JSON.parse(response.body)
    assert_equal "not_amortizable", json["error"]
  end

  test "requires API key authentication" do
    loan = @loan_account.accountable
    get api_v1_loan_amortization_schedule_path(loan)
    assert_response :unauthorized
  end

  test "returns 404, not 403, for a loan belonging to another family" do
    other_user = users(:empty) # admin of the `empty` family, unrelated to dylan_family
    other_api_key = ApiKey.create!(
      user: other_user,
      name: "Other Family Loan API Test Key",
      scopes: [ "read" ],
      source: "web",
      key: ApiKey.generate_secure_key
    )

    loan = @loan_account.accountable
    get api_v1_loan_amortization_schedule_path(loan),
        headers: api_headers(other_api_key)
    # A distinct status here (e.g. 403) would let a caller enumerate loan ids
    # that exist but aren't theirs, so this must be indistinguishable from a
    # nonexistent loan.
    assert_response :not_found
    assert_equal "not_found", JSON.parse(response.body)["error"]
  end

  test "returns 404 for a family member the loan's account is not shared with" do
    member = users(:family_member)
    assert_not @loan_account.shared_with?(member), "precondition: not shared"
    member_key = ApiKey.create!(user: member, name: "Member Loan Key", scopes: [ "read" ], source: "web", key: ApiKey.generate_secure_key)

    get api_v1_loan_amortization_schedule_path(@loan_account.accountable), headers: api_headers(member_key)

    assert_response :not_found
  end

  test "returns 404 for non-existent loan" do
    get api_v1_loan_amortization_schedule_path("00000000-0000-0000-0000-000000000000"),
        headers: api_headers
    assert_response :not_found
  end

  private
    def create_loan_account(name:, subtype: "mortgage", interest_rate: 3.5, rate_type: "fixed", term_months: 360, start_date: nil)
      Account.create!(
        family: @family,
        owner: @user,
        name: name,
        balance: 500000,
        currency: "USD",
        accountable: Loan.create!(
          subtype: subtype,
          interest_rate: interest_rate,
          term_months: term_months,
          rate_type: rate_type,
          start_date: start_date
        )
      )
    end

    def create_anchored_loan(start_date:, term_months: 360)
      account = create_loan_account(name: "Anchored #{SecureRandom.hex(3)}", start_date: start_date, term_months: term_months)
      account.entries.create!(
        name: "Starting balance",
        amount: 500000,
        currency: "USD",
        date: start_date,
        entryable: Valuation.new(kind: "opening_anchor")
      )
      account.reload
    end

    def capture_sql
      queries = []
      subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
        queries << payload[:sql] unless payload[:name].in?([ "SCHEMA", "TRANSACTION" ])
      end
      yield
      queries
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end
end
