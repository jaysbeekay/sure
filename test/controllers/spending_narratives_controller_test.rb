require "test_helper"

class SpendingNarrativesControllerTest < ActionDispatch::IntegrationTest
  include EntriesTestHelper

  # A month no fixture touches, so every figure on the page is one the test made.
  TODAY = Date.new(2024, 3, 14)

  setup do
    sign_in @user = users(:family_admin)
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => true))
    @family = @user.family
    @dining = @family.categories.create!(name: "Story Dining", color: "#101010", lucide_icon: "circle")
    ensure_tailwind_build
  end

  def visit
    travel_to(TODAY) { get spending_narrative_url }
  end

  def create_budget(budgeted: 1000)
    Budget.create!(family: @family, start_date: Date.new(2024, 3, 1), end_date: Date.new(2024, 3, 31),
                   budgeted_spending: budgeted, expected_income: 0, currency: "USD")
  end

  def spend(amount, date, category: @dining)
    create_transaction(category: category, amount: amount, date: date, name: "Story #{amount}")
  end

  def hrefs
    css_select("a").map { |a| a["href"] }
  end

  def query_of(href)
    Rack::Utils.parse_nested_query(URI.parse(href).query.to_s).fetch("q", {})
  end

  test "redirects users without preview access" do
    @user.update!(preferences: @user.preferences.merge("preview_features_enabled" => false))

    get spending_narrative_url

    assert_redirected_to root_path
    assert_match(/preview/i, flash[:alert])
  end

  test "renders for users with preview access" do
    visit

    assert_response :success
    assert_select "h1", text: I18n.t("spending_narratives.show.title")
  end

  test "without a budget the page still tells the rest of the story and creates nothing" do
    spend(300, Date.new(2024, 3, 3))

    assert_no_difference "Budget.count" do
      visit
    end

    assert_response :success
    assert_select "[data-testid=pace-empty]"
    assert_select "[data-testid=pace-status]", count: 0
    assert_select "[data-testid=top-movers]"
    assert_select "[data-testid=heatmap]"
  end

  test "pace shows the status, the figures and a way to the budget" do
    budget = create_budget
    spend(1300, Date.new(2024, 3, 3))

    visit

    assert_response :success
    assert_select "[data-testid=pace-status]", text: I18n.t("spending_narratives.show.pace.status.over")
    assert_select "[data-testid=pace] .privacy-sensitive", text: /\$1,300\.00/
    assert_select "[data-testid=pace] a[href=?]", budget_path(Budget.date_to_param(budget.start_date))
  end

  test "the status follows the spend against the date, not just the spend" do
    create_budget
    spend(300, Date.new(2024, 3, 3))

    # 14 of 31 days gone: 300 of 1000 is 30%, behind the 45% clock.
    visit
    assert_select "[data-testid=pace-status]", text: I18n.t("spending_narratives.show.pace.status.on_track")

    spend(400, Date.new(2024, 3, 4))
    visit
    assert_select "[data-testid=pace-status]", text: I18n.t("spending_narratives.show.pace.status.approaching")
  end

  test "spend dated after today does not make the page say over budget" do
    create_budget
    spend(100, Date.new(2024, 3, 5))
    spend(1500, Date.new(2024, 3, 20))

    visit

    assert_select "[data-testid=pace-status]", text: I18n.t("spending_narratives.show.pace.status.on_track")
  end

  # The pace insight is the household's, and links here with owner=household so
  # the page shows the budget the card was about, not the reader's own.
  test "owner=household shows the household budget; the default shows the viewer's own" do
    @family.update!(personal_budgets: true)
    Budget.create!(family: @family, start_date: Date.new(2024, 3, 1), end_date: Date.new(2024, 3, 31),
                   budgeted_spending: 1000, expected_income: 0, currency: "USD")
    Budget.create!(family: @family, user: @user, start_date: Date.new(2024, 3, 1), end_date: Date.new(2024, 3, 31),
                   budgeted_spending: 9000, expected_income: 0, currency: "USD")
    spend(1300, Date.new(2024, 3, 3))

    visit
    assert_select "[data-testid=pace-status]", text: I18n.t("spending_narratives.show.pace.status.on_track")
    assert_select "[data-testid=pace]", text: /\$9,000\.00/

    travel_to(TODAY) { get spending_narrative_url(owner: "household") }
    assert_select "[data-testid=pace-status]", text: I18n.t("spending_narratives.show.pace.status.over")
    assert_select "[data-testid=pace]", text: /\$1,000\.00/
  end

  test "a top mover links to that category's transactions over the period" do
    spend(100, Date.new(2024, 2, 20))
    spend(700, Date.new(2024, 3, 3))

    visit

    link = hrefs.find { |href| href.to_s.start_with?("/transactions") && query_of(href)["categories"] == [ "Story Dining" ] }
    assert link, "expected a transactions link for the category, got #{hrefs.grep(/transactions/).inspect}"
    q = query_of(link)
    assert_equal "2024-03-01", q["start_date"]
    assert_equal "2024-03-14", q["end_date"]
    assert_select "[data-testid=top-movers]", text: /\+\$600\.00/
  end

  test "a heatmap cell links to its own day and a week row to its week" do
    spend(120, Date.new(2024, 3, 4)) # a Monday

    visit

    day_links = hrefs.select { |h| h.to_s.start_with?("/transactions") && query_of(h) == { "start_date" => "2024-03-04", "end_date" => "2024-03-04" } }
    week_links = hrefs.select { |h| h.to_s.start_with?("/transactions") && query_of(h) == { "start_date" => "2024-03-03", "end_date" => "2024-03-09" } }
    assert_equal 1, day_links.size, "the cell for Monday 4 March"
    assert_operator week_links.size, :>=, 1, "the row for the week of 3 March"
  end

  test "the heatmap grand total is the net spend for the period" do
    spend(120, Date.new(2024, 3, 4))
    spend(-20, Date.new(2024, 3, 6))

    visit

    assert_select "[data-testid=heatmap-total]", text: "$100.00"
  end

  test "the page says the hour axis is not available and why" do
    visit

    assert_select "[data-testid=heatmap-note]", text: I18n.t("spending_narratives.show.heatmap.note")
    assert_match(/time of day|hour/i, I18n.t("spending_narratives.show.heatmap.note"))
  end

  test "another family's data never appears" do
    other = families(:empty)
    account = Account.create!(family: other, name: "Other", balance: 0, currency: "USD", accountable: Depository.new)
    other_category = other.categories.create!(name: "Other family secret", color: "#101010", lucide_icon: "circle")
    Entry.create!(account: account, name: "Other", date: Date.new(2024, 3, 3), currency: "USD", amount: 4242,
                  entryable: Transaction.new(category: other_category))
    Budget.create!(family: other, start_date: Date.new(2024, 3, 1), end_date: Date.new(2024, 3, 31),
                   budgeted_spending: 10, expected_income: 0, currency: "USD")
    spend(100, Date.new(2024, 3, 3))

    visit

    assert_no_match(/Other family secret/, response.body)
    assert_no_match(/4,242/, response.body)
    assert_select "[data-testid=heatmap-total]", text: "$100.00"
    assert_select "[data-testid=pace-empty]"
  end

  # The page counts the viewer's accounts, as the budget does: spending on an
  # account a member does not include in their finances is not theirs to see here.
  test "the page is scoped to the viewer's own accounts" do
    private_account = Account.create!(family: @family, owner: @user, name: "Admin only", balance: 0, currency: "USD", accountable: Depository.new)
    create_transaction(account: private_account, category: @dining, amount: 400, date: Date.new(2024, 3, 3), name: "Private")

    visit
    assert_select "[data-testid=heatmap-total]", text: "$400.00"

    member = users(:family_member)
    assert_not_includes member.finance_accounts.pluck(:id), private_account.id
    member.update!(preferences: (member.preferences || {}).merge("preview_features_enabled" => true))
    sign_in member
    visit

    assert_response :success
    assert_select "[data-testid=heatmap-total]", count: 0
    assert_no_match(/Story Dining/, response.body)
  end

  test "the whole page reads one date" do
    create_budget
    spend(300, Date.new(2024, 3, 3))

    visit

    assert_select "[data-testid=narrative-period]", text: /Mar 01/
    assert_select "[data-testid=narrative-period]", text: /Mar 14/
  end
end
