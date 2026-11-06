require "test_helper"

class Portfolio::SectionRegistryTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @family = @user.family
    @period = Period.last_30_days
    @as_of = Date.current
    @statement = InvestmentStatement.new(@family, user: @user)
  end

  test "registers the built-in sections with their partials and locals" do
    sections = registry.sections

    assert_equal Portfolio::SectionRegistry::KEYS, sections.map { |s| s[:key] }
    assert_equal %w[portfolios/accounts portfolios/data_quality], sections.map { |s| s[:partial] }
    assert sections.all? { |s| s[:collapsible] }

    # Every partial gets its locals passed in: none of them reaches for
    # Date.current or Current.family on its own.
    sections.each do |section|
      assert_equal({ statement: @statement, period: @period, as_of: @as_of }, section[:locals].slice(:statement, :period, :as_of),
        "#{section[:key]} must receive the shared locals rather than reading them itself")
    end
  end

  test "the accounts section is visible only when the family has investment accounts" do
    assert registry.sections.find { |s| s[:key] == "accounts" }[:visible]

    empty_statement = InvestmentStatement.new(families(:empty), user: nil)
    empty = Portfolio::SectionRegistry.new(statement: empty_statement, period: @period, as_of: @as_of, user: @user).sections
    assert_not empty.find { |s| s[:key] == "accounts" }[:visible]
  end

  # Created in reverse name order, so the cards come back by name only if the
  # query asks for it.
  test "the accounts section lists the cards in name order" do
    zeta = @family.accounts.create!(name: "Zeta brokerage", balance: 100, currency: "USD", accountable: Investment.new, owner: @user)
    alpha = @family.accounts.create!(name: "Alpha brokerage", balance: 100, currency: "USD", accountable: Investment.new, owner: @user)
    @statement = InvestmentStatement.new(@family, user: @user)

    cards = registry.sections.find { |s| s[:key] == "accounts" }[:locals][:accounts]

    assert_includes cards, zeta
    assert_operator cards.index(alpha), :<, cards.index(zeta)
    assert_equal @statement.investment_accounts.to_a.sort_by(&:id), cards.sort_by(&:id),
      "the cards must be exactly the statement's investment accounts"
  end

  # Stubbed with the registry's own as_of, so a registry that let the
  # statement default the date would miss the stub and fail.
  test "the data quality section shows the statement's issues, and only when there are some" do
    holding = holdings(:one)
    issue = InvestmentStatement::DataQualityIssue.new(kind: :missing_cost_basis, holding: holding, security: holding.security, detail: nil)

    @statement.stubs(:data_quality_issues).with(as_of: @as_of).returns([ issue ])
    section = registry.sections.find { |s| s[:key] == "data_quality" }
    assert section[:visible]
    assert_equal [ issue ], section[:locals][:issues]
    assert_includes section[:locals][:writable_account_ids], holding.account_id

    @statement = InvestmentStatement.new(@family, user: @user)
    @statement.stubs(:data_quality_issues).with(as_of: @as_of).returns([])
    section = registry.sections.find { |s| s[:key] == "data_quality" }
    assert_not section[:visible], "an empty data quality section would read as a problem in itself"
    assert_empty section[:locals][:writable_account_ids]
  end

  test "orders sections by the user's saved order, appending anything it omits" do
    @user.update_section_preferences("portfolio", order: %w[stub])

    assert_equal %w[stub accounts data_quality], registry(extra_sections: [ stub_section ]).sections.map { |s| s[:key] }
  end

  test "a saved order that repeats a key renders that section once" do
    @user.update_section_preferences("portfolio", order: %w[stub accounts stub])

    keys = registry(extra_sections: [ stub_section ]).sections.map { |s| s[:key] }

    assert_equal %w[stub accounts data_quality], keys
  end

  test "ignores keys in the saved order that no longer exist" do
    @user.update_section_preferences("portfolio", order: %w[gone accounts])

    assert_equal %w[accounts data_quality], registry.sections.map { |s| s[:key] }
  end

  test "appends extra sections after the built-ins" do
    sections = registry(extra_sections: [ stub_section ]).sections

    assert_equal %w[accounts data_quality stub], sections.map { |s| s[:key] }
  end

  private
    def stub_section
      { key: "stub", title: "portfolios.sections.accounts", partial: "portfolios/accounts",
        locals: {}, visible: true, collapsible: true }
    end

    def registry(extra_sections: [])
      Portfolio::SectionRegistry.new(
        statement: @statement,
        period: @period,
        as_of: @as_of,
        user: @user,
        extra_sections: extra_sections
      )
    end
end
