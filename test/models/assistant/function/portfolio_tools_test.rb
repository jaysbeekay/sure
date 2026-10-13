require "test_helper"

# #131, 12.1. The three portfolio tools report the figures the portfolio pages
# show the same user (InvestmentStatement for that user), and count only the
# accounts that user includes in their finances.
class Assistant::Function::PortfolioToolsTest < ActiveSupport::TestCase
  include PortfolioReturnsTestHelper

  setup do
    @admin = users(:family_admin)
    @member = users(:family_member)
    @family = @admin.family
    @day_one = Date.current - 5.days
    @day_two = Date.current - 4.days

    # The member's brokerage, shared with the admin. Whether the admin counts
    # it is the share's include_in_finances flag.
    @shared = create_portfolio_account(family: @family, name: "Member brokerage", balance: 2_310)
    @shared.update!(owner: @member)
    @share = @shared.account_shares.create!(user: @admin, permission: "read_only", include_in_finances: true)
    lay_balance account: @shared, date: @day_one, opening: 1_000, closing: 1_100, market_flow: 100
    lay_balance account: @shared, date: @day_two, opening: 1_100, closing: 2_310, cash_flow: 1_000, market_flow: 210
    deposit account: @shared, date: @day_two, amount: 1_000
    income_trade account: @shared, date: @day_two, amount: 25
  end

  # ------------------------------------------------------- same figures

  test "performance reports the investment statement's figures for the same user and period" do
    result = call(Assistant::Function::GetPortfolioPerformance, { "period" => "last_30_days" })
    expected = InvestmentStatement.new(@family, user: @admin).performance(period: Period.from_key("last_30_days"))

    assert result[:available]
    assert_equal expected.time_weighted_return.to_d.round(6).to_f, result[:time_weighted_return][:value]
    assert_equal expected.drivers.to_h[:value_close].to_d.round(2).to_f, result[:drivers][:value_close][:amount]
    assert_equal expected.rate_missing?, result[:rate_missing]
  end

  test "allocation reports the investment statement's segments for the same user" do
    result = call(Assistant::Function::GetPortfolioAllocation, { "by" => "account" })
    expected = InvestmentStatement.new(@family, user: @admin).allocation_by("account")

    assert_equal expected.map(&:id).sort, result[:segments].map { |s| s[:id] }.sort
    segment = result[:segments].find { |s| s[:id] == @shared.id }
    assert_equal (expected.find { |s| s.id == @shared.id }.weight.to_d / 100).round(6).to_f, segment[:weight][:value]
  end

  # The model's segment weight is already a percentage (25 for a quarter). The
  # tool reports it as a fraction like every other rate it returns, so the
  # weights of one dimension add up to 1, not 100.
  test "allocation weights are fractions of the total, formatted as percentages" do
    result = call(Assistant::Function::GetPortfolioAllocation, { "by" => "account" })

    assert_in_delta 1.0, result[:segments].sum { |s| s[:weight][:value] }, 0.0001
    segment = result[:segments].find { |s| s[:id] == @shared.id }
    assert_equal "#{(segment[:weight][:value].to_d * 100).round(2).to_s("F")}%", segment[:weight][:formatted]
  end

  test "income reports the statement's income for the same user and period" do
    result = call(Assistant::Function::GetIncomeSummary, { "period" => "last_30_days" })
    expected = InvestmentStatement.new(@family, user: @admin).performance(period: Period.from_key("last_30_days")).income

    assert result[:available]
    assert_equal expected[:total].to_d.round(2).to_f, result[:total][:amount]
    assert_operator result[:total][:amount], :>=, 25
  end

  # ---------------------------------------- included_in_finances_for(user)

  # Measured as a delta: the same account, the same history, and only the
  # share's include_in_finances flag changed.
  test "an account shared without include_in_finances leaves every tool's figures" do
    with_shared = figures

    @share.update!(include_in_finances: false)
    without_shared = figures

    assert_includes with_shared[:allocation_ids], @shared.id
    assert_not_includes without_shared[:allocation_ids], @shared.id
    assert_operator with_shared[:value_close], :>, without_shared[:value_close].to_f
    assert_in_delta with_shared[:income] - 25, without_shared[:income], 0.001
  end

  # The owner always counts their own account, whatever they share.
  test "the owner's own figures include their account" do
    member_ids = call(Assistant::Function::GetPortfolioAllocation, { "by" => "account" }, @member)[:segments].map { |s| s[:id] }

    assert_includes member_ids, @shared.id
  end

  # ------------------------------------------------------- what is refused

  test "a period with no investment history says so instead of failing" do
    result = call(Assistant::Function::GetPortfolioPerformance, { "period" => "last_30_days" }, users(:empty))

    assert_equal false, result[:available]
    assert_match(/No investment/, result[:message])
  end

  test "an unknown period, a half range or a bad date is an error, not a default" do
    tool = Assistant::Function::GetPortfolioPerformance

    assert_equal "invalid_period", call(tool, { "period" => "all_time" })[:error]
    assert_equal "invalid_date", call(tool, { "start_date" => @day_one.iso8601 })[:error]
    assert_equal "invalid_date", call(tool, { "start_date" => "2026-02-30", "end_date" => "2026-03-01" })[:error]
    assert_equal "invalid_date", call(tool, { "start_date" => @day_two.iso8601, "end_date" => @day_one.iso8601 })[:error]
  end

  test "a custom range is the period reported" do
    result = call(Assistant::Function::GetPortfolioPerformance, { "start_date" => @day_one.iso8601, "end_date" => @day_two.iso8601 })

    assert_equal @day_one, result[:period][:start_date]
    assert_equal @day_two, result[:period][:end_date]
  end

  test "look_through is refused on a dimension it does not apply to" do
    result = call(Assistant::Function::GetPortfolioAllocation, { "by" => "account", "look_through" => true })

    assert_equal "invalid_look_through", result[:error]
  end

  # R13: a missing rate withholds the return; the tool must not report 0.
  test "a withheld return is reported as null with rate_missing, not as zero" do
    Portfolio::Performance.any_instance.stubs(:rate_missing?).returns(true)
    Portfolio::Performance.any_instance.stubs(:time_weighted_return).returns(nil)

    result = call(Assistant::Function::GetPortfolioPerformance, { "period" => "last_30_days" })

    assert result[:rate_missing]
    assert_nil result[:time_weighted_return]
  end

  # ------------------------------------------------ income, as the page shows it

  # A dividend with no security recorded, and one naming a security this
  # install does not have, are both in the total. The table has to carry them
  # as the unattributed remainder or it sums to less than the total beside it.
  test "income by security plus unattributed adds up to the total" do
    income_transaction account: @shared, date: @day_two, amount: 40
    income_transaction account: @shared, date: @day_two, amount: 7, extra: { "security_id" => SecureRandom.uuid }

    result = call(Assistant::Function::GetIncomeSummary, { "period" => "last_30_days" })
    rows_sum = result[:by_security].sum { |row| row[:income][:amount] }

    assert_in_delta 72, result[:total][:amount], 0.001, "the fixture's three payments are all in the total"
    assert_in_delta 25, rows_sum, 0.001, "only the security this install knows is a row"
    assert_in_delta 47, result[:unattributed][:amount], 0.001
    assert_in_delta result[:total][:amount], rows_sum + result[:unattributed][:amount], 0.001
    assert result[:by_security].all? { |row| row[:ticker].present? }, "an unknown security is not a nameless row"
  end

  # Built from a real rateless fixture: a EUR account with no EUR rate.
  test "income reports rate_missing when a currency has no rate" do
    assert_equal false, call(Assistant::Function::GetIncomeSummary, { "period" => "last_30_days" })[:rate_missing],
                 "the control: with every rate present, nothing is missing"

    eur = create_portfolio_account(family: @family, currency: "EUR", balance: 1_000)
    eur.update!(owner: @admin)
    lay_balance account: eur, date: @day_one, opening: 1_000, closing: 1_000
    lay_balance account: eur, date: @day_two, opening: 1_000, closing: 1_000
    income_trade account: eur, date: @day_two, amount: 3

    result = call(Assistant::Function::GetIncomeSummary, { "period" => "last_30_days" })

    assert_equal true, result[:rate_missing]
    assert_nil result[:fee_ratio]
  end

  # ------------------------------------------------- availability

  # An account in scope with no balance rows in the period gives a row per
  # calendar day all the same, so the model's any? is true and its return
  # chains to 0%. Neither tool may report that as a measured portfolio.
  test "an account with no balance history is not available" do
    user = users(:empty)
    account = create_portfolio_account(family: user.family, name: "Unfunded brokerage")
    account.update!(owner: user)

    performance = call(Assistant::Function::GetPortfolioPerformance, { "period" => "last_30_days" }, user)
    income = call(Assistant::Function::GetIncomeSummary, { "period" => "last_30_days" }, user)

    assert_equal false, performance[:available]
    assert_nil performance[:time_weighted_return]
    assert_equal false, income[:available]

    lay_balance account: account, date: @day_one, opening: 0, closing: 500, cash_flow: 500
    lay_balance account: account, date: @day_two, opening: 500, closing: 500

    assert call(Assistant::Function::GetPortfolioPerformance, { "period" => "last_30_days" }, user)[:available],
           "the same account with history is available"
    assert call(Assistant::Function::GetIncomeSummary, { "period" => "last_30_days" }, user)[:available]
  end

  # ------------------------------------------------- periods

  test "last_month follows the family's custom month start" do
    @family.update!(month_start_day: 15)
    expected = Period.last_month_for(@family)
    assert_not_equal Period.from_key("last_month").start_date, expected.start_date, "the fixture really moves the month"

    result = call(Assistant::Function::GetPortfolioPerformance, { "period" => "last_month" })

    assert_equal expected.start_date, result[:period][:start_date]
    assert_equal expected.end_date, result[:period][:end_date]
  end

  # ------------------------------------------------- look-through

  # The page offers look-through only when a held fund has known constituents,
  # and never rejects it. The tool reports whether it was actually applied.
  test "look_through reports whether it was applied, not just requested" do
    fund = Security.create!(ticker: "MIX#{SecureRandom.hex(3)}", name: "A fund", asset_class: "equity", asset_sub_class: "etf")
    Holding.create!(account: @shared, security: fund, date: Date.current, qty: 1, price: 1_000, amount: 1_000, currency: "USD")

    without = call(Assistant::Function::GetPortfolioAllocation, { "by" => "asset_class", "look_through" => true })
    assert_nil without[:error], "a request with nothing to look through is not refused"
    assert_equal false, without[:look_through]

    fund.constituents.create!(ticker: "SHR#{SecureRandom.hex(3)}", name: "A share", weight: 100)
    with = call(Assistant::Function::GetPortfolioAllocation, { "by" => "asset_class", "look_through" => true })
    assert_equal true, with[:look_through]

    assert_equal false, call(Assistant::Function::GetPortfolioAllocation, { "by" => "asset_class" })[:look_through],
                 "not requested is not applied, constituents or not"
  end

  # ------------------------------------------------- withheld figures

  # A valuation-tracked account has no record of money paid in, so the
  # portfolio's money-weighted return is withheld (R16). The output has to say
  # which account withholds it and why, not just print null.
  test "return_scopes says which method each account supports and why one is withheld" do
    valued = create_portfolio_account(family: @family, name: "Valued account", balance: 600)
    valued.update!(owner: @admin)
    valued.entries.create!(name: "Valuation", date: @day_one, amount: 500, currency: "USD", entryable: Valuation.new)
    lay_balance account: valued, date: @day_one, opening: 500, closing: 500
    lay_balance account: valued, date: @day_two, opening: 500, closing: 600, revaluation: 100

    result = call(Assistant::Function::GetPortfolioPerformance, { "period" => "last_30_days" })
    scopes = result[:return_scopes].index_by { |scope| scope[:account_id] }

    assert_nil result[:money_weighted_return], "the fixture really withholds the money-weighted return"
    assert_equal "trade_tracked", scopes[@shared.id][:tracking]
    assert_equal true, scopes[@shared.id][:money_weighted_return]
    assert_nil scopes[@shared.id][:withheld_because]
    assert_equal "valuation_tracked", scopes[valued.id][:tracking]
    assert_equal true, scopes[valued.id][:time_weighted_return]
    assert_equal false, scopes[valued.id][:money_weighted_return]
    assert_match(/money-weighted/, scopes[valued.id][:withheld_because])
  end

  test "an account with one day of history is named as withholding every return" do
    newcomer = create_portfolio_account(family: @family, name: "New account", balance: 300)
    newcomer.update!(owner: @admin)
    lay_balance account: newcomer, date: @day_two, opening: 0, closing: 300, cash_flow: 300

    result = call(Assistant::Function::GetPortfolioPerformance, { "period" => "last_30_days" })
    scope = result[:return_scopes].find { |row| row[:account_id] == newcomer.id }

    assert_nil result[:time_weighted_return], "the fixture really withholds the time-weighted return"
    assert_equal "insufficient", scope[:tracking]
    assert_equal false, scope[:time_weighted_return]
    assert_match(/two days/, scope[:withheld_because])
  end

  # The money-weighted figure is expressed over the whole period, so the tool
  # describes it in the page's own words rather than as "what the money earned".
  test "the performance description reuses the page's money-weighted wording" do
    description = Assistant::Function::GetPortfolioPerformance.description

    assert_includes description.squish, I18n.t("portfolios.performance.mwr_hint", locale: :en).squish
    assert_no_match(/actually earned/, description)
    assert_match(/return_scopes/, description)
  end

  test "the income description explains rate_missing" do
    assert_match(/rate_missing/, Assistant::Function::GetIncomeSummary.description)
  end

  # ------------------------------------------------------------ registry

  test "the tools are offered only to a user with preview features, in chat and over MCP" do
    names = ->(user) { Assistant.function_classes(user).map(&:name) }
    tools = %w[get_portfolio_performance get_portfolio_allocation get_income_summary]

    @admin.update!(preferences: (@admin.preferences || {}).merge("preview_features_enabled" => false))
    assert_empty tools & names.call(@admin)

    @admin.update!(preferences: (@admin.preferences || {}).merge("preview_features_enabled" => true))
    assert_equal tools.sort, (tools & names.call(@admin)).sort
  end

  private
    def call(tool, params = {}, user = @admin)
      tool.new(user).call(params)
    end

    def figures
      performance = call(Assistant::Function::GetPortfolioPerformance, { "period" => "last_30_days" })
      income = call(Assistant::Function::GetIncomeSummary, { "period" => "last_30_days" })
      allocation = call(Assistant::Function::GetPortfolioAllocation, { "by" => "account" })

      {
        value_close: performance.dig(:drivers, :value_close, :amount).to_f,
        income: income.dig(:total, :amount).to_f,
        allocation_ids: allocation[:segments].map { |s| s[:id] }
      }
    end
end
