require "test_helper"

class Insight::Generators::StaleValuationGeneratorTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @property = accounts(:property)
    # The fixture accounts are created "now" with no valuation entries, which is
    # the one state the generator must say nothing about. Every test sets the
    # age it is exercising explicitly rather than leaning on that default.
    [ accounts(:other_asset), accounts(:other_liability), accounts(:vehicle) ].each { |a| settle(a) }
  end

  test "flags a manual property last valued 91 days ago" do
    value_on(@property, 91.days.ago.to_date)

    insights = generate

    assert_equal 1, insights.size
    insight = insights.first
    assert_equal "stale_valuation", insight.insight_type
    assert_equal "low", insight.priority
    assert_equal @property.id, insight.metadata[:account_id]
    assert_equal 91.days.ago.to_date.iso8601, insight.metadata[:last_valued_on]
    assert_not_includes insight.facts.keys, :days
  end

  test "says nothing at exactly the threshold" do
    value_on(@property, 90.days.ago.to_date)

    assert_empty generate
  end

  test "valuing the account clears the insight on the next run" do
    value_on(@property, 91.days.ago.to_date)
    assert_equal 1, generate.size

    add_valuation(@property, Date.current)

    assert_empty generate
  end

  test "a vehicle, an other asset and an other liability qualify the same way" do
    value_on(accounts(:vehicle), 120.days.ago.to_date)
    value_on(accounts(:other_asset), 120.days.ago.to_date)
    value_on(accounts(:other_liability), 120.days.ago.to_date)

    assert_equal [ accounts(:other_asset), accounts(:other_liability), accounts(:vehicle) ].map(&:id).sort,
                 generate.map { |i| i.metadata[:account_id] }.sort
  end

  test "the family threshold decides what is stale" do
    value_on(@property, 31.days.ago.to_date)
    assert_empty generate

    @family.update!(stale_valuation_days: 30)

    assert_equal [ @property.id ], generate.map { |i| i.metadata[:account_id] }
  end

  test "ignores accounts that are not manually valued" do
    value_on(@property, 400.days.ago.to_date)
    account = accounts(:depository)
    value_on(account, 400.days.ago.to_date)

    assert_equal [ @property.id ], generate.map { |i| i.metadata[:account_id] }
  end

  test "ignores a property fed by a sync provider" do
    value_on(@property, 400.days.ago.to_date)
    @property.update_columns(plaid_account_id: plaid_accounts(:one).id)

    assert_not @property.reload.manual?, "precondition: the account must no longer be manual"
    assert_empty generate
  end

  test "ignores a disabled account" do
    value_on(@property, 400.days.ago.to_date)
    @property.update_columns(status: "disabled")

    assert_empty generate
  end

  test "ignores a draft account whose setup is unfinished" do
    value_on(@property, 400.days.ago.to_date)
    @property.update_columns(status: "draft")

    assert_empty generate
  end

  # Opening anchors are back-dated by design, so a property added today with an
  # opening value two years ago has not been neglected for two years.
  test "a new account with a back-dated opening value is not stale" do
    @property.entries.destroy_all
    @property.entries.create!(
      name: "Opening", date: 2.years.ago.to_date, amount: 550_000, currency: "USD",
      entryable: Valuation.new(kind: "opening_anchor")
    )
    @property.update_columns(created_at: Time.current)

    assert_empty generate
  end

  test "an account created long ago with only a back-dated opening value is stale" do
    @property.entries.destroy_all
    @property.entries.create!(
      name: "Opening", date: 2.years.ago.to_date, amount: 550_000, currency: "USD",
      entryable: Valuation.new(kind: "opening_anchor")
    )
    @property.update_columns(created_at: 100.days.ago)

    insights = generate

    assert_equal [ @property.id ], insights.map { |i| i.metadata[:account_id] }
    assert_equal 100.days.ago.to_date.iso8601, insights.first.metadata[:last_valued_on]
  end

  test "reports the oldest three when more are stale" do
    value_on(@property, 100.days.ago.to_date)
    value_on(accounts(:vehicle), 400.days.ago.to_date)
    value_on(accounts(:other_asset), 300.days.ago.to_date)
    value_on(accounts(:other_liability), 200.days.ago.to_date)

    assert_equal [ accounts(:vehicle), accounts(:other_asset), accounts(:other_liability) ].map(&:id),
                 generate.map { |i| i.metadata[:account_id] }
  end

  test "a fourth stale account is reported once one of the three is valued" do
    value_on(@property, 100.days.ago.to_date)
    value_on(accounts(:vehicle), 400.days.ago.to_date)
    value_on(accounts(:other_asset), 300.days.ago.to_date)
    value_on(accounts(:other_liability), 200.days.ago.to_date)
    assert_not_includes generate.map { |i| i.metadata[:account_id] }, @property.id, "precondition: the newest is cut"

    add_valuation(accounts(:vehicle), Date.current)

    assert_equal [ accounts(:other_asset), accounts(:other_liability), @property ].map(&:id),
                 generate.map { |i| i.metadata[:account_id] }
  end

  test "the dedup key carries the account and the month" do
    value_on(@property, 91.days.ago.to_date)

    assert_equal "stale_valuation:#{@property.id}:#{Date.current.strftime("%Y-%m")}", generate.first.dedup_key
  end

  # The balance drifts with every valuation; if it sat in metadata it would
  # rewrite the body and resurrect a dismissed card nightly.
  test "the balance is a fact, not part of the metadata that decides resurfacing" do
    value_on(@property, 91.days.ago.to_date)

    insight = generate.first

    assert_not_includes insight.metadata.keys, :balance
    assert_equal Money.new(@property.balance, "USD").format, insight.facts[:balance]
  end

  # The body is written once and kept until the numbers change materially, so it
  # must not carry anything that ages: a count of days would be wrong by the next
  # night.
  test "the stored prose carries no day count that would age" do
    @family.users.update_all(ai_enabled: false)
    value_on(@property, 91.days.ago.to_date)

    generated = generate.first
    body = Insight::BodyWriter.new(@family).write(generated)

    assert_no_match(/\b91\b/, body)
    assert_includes body, generated.facts[:last_valued_on]
  end

  test "writes the insight in German" do
    @family.users.update_all(ai_enabled: false)
    value_on(@property, 91.days.ago.to_date)

    generated = I18n.with_locale(:de) { generate.first }
    body = I18n.with_locale(:de) { Insight::BodyWriter.new(@family).write(generated) }

    assert_includes generated.title, @property.name
    assert_not_equal I18n.t("insights.titles.stale_valuation", account: @property.name, locale: :en), generated.title
    assert_includes body, generated.facts[:balance]
  end

  private
    def generate
      Insight::Generators::StaleValuationGenerator.new(@family.reload).generate
    end

    # An account valued today and created long ago: fresh, whatever else is true.
    def settle(account)
      value_on(account, Date.current)
    end

    # Leaves the account with exactly one valuation, on `date`, and an age that
    # makes `date` the newest thing known about it.
    def value_on(account, date)
      account.entries.destroy_all
      add_valuation(account, date)
      account.update_columns(created_at: date.beginning_of_day)
    end

    def add_valuation(account, date)
      account.entries.create!(
        name: "Valuation #{date}", date: date, amount: account.balance, currency: account.currency,
        entryable: Valuation.new(kind: "reconciliation")
      )
    end
end
