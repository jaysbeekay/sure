require "test_helper"

class Transactions::CategorySuggestionsControllerTest < ActionDispatch::IntegrationTest
  include EntriesTestHelper, ProviderTestHelper

  AutoCategorization = Provider::LlmConcept::AutoCategorization

  setup do
    sign_in @user = users(:family_admin)
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => true))
    @family = @user.family
    @family.accounts.each { |a| a.entries.delete_all }
    @account = accounts(:depository)
    @category = categories(:food_and_drink)
    @other_category = categories(:income)
    @llm = mock
    Provider::Registry.stubs(:preferred_llm_provider).returns(@llm)
  end

  # preview gate

  test "every action redirects users without preview access, and does nothing" do
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => false))
    txn = create_transaction(account: @account, name: "Coffee").transaction
    @llm.expects(:auto_categorize).never

    get transactions_category_suggestions_url
    assert_redirected_to root_path

    post transactions_category_suggestions_url
    assert_redirected_to root_path

    assert_no_difference "DataEnrichment.count" do
      post accept_transactions_category_suggestions_url,
           params: { suggestions: { "0" => { transaction_id: txn.id, category_id: @category.id } } }
    end
    assert_redirected_to root_path
    assert_nil txn.reload.category_id
  end

  # entry point

  test "the transactions menu links to the review page for preview users with a backlog" do
    create_transaction(account: @account, name: "Coffee")

    get transactions_url

    assert_select "a[href='#{transactions_category_suggestions_path}']", count: 1
  end

  test "the transactions menu does not show the link without preview access" do
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => false))
    create_transaction(account: @account, name: "Coffee")

    get transactions_url

    assert_select "a[href='#{transactions_category_suggestions_path}']", count: 0
  end

  test "the transactions menu does not show the link when nothing is uncategorized" do
    get transactions_url

    assert_select "a[href='#{transactions_category_suggestions_path}']", count: 0
  end

  # index

  test "index shows the backlog count and the cost of one batch, capped at 25" do
    create_backlog(26)
    LlmUsage.expects(:estimate_auto_categorize_cost).with { |transaction_count:, **| transaction_count == 25 }.returns(0.0123)

    get transactions_category_suggestions_url

    assert_response :success
    assert_match I18n.t("transactions.category_suggestions.index.backlog", count: 26), response.body
    assert_match "0.0123", response.body
    assert_select "button", text: I18n.t("transactions.category_suggestions.index.suggest")
  end

  test "index says there is no pricing rather than inventing a cost" do
    create_backlog(2)
    LlmUsage.stubs(:estimate_auto_categorize_cost).returns(nil)

    get transactions_category_suggestions_url

    assert_response :success
    assert_no_match(/~\$/, response.body)
    assert_match I18n.t("transactions.category_suggestions.index.cost_unavailable"), response.body
    assert_select "button", text: I18n.t("transactions.category_suggestions.index.suggest")
  end

  test "index with no provider explains and offers no button" do
    Provider::Registry.stubs(:preferred_llm_provider).returns(nil)
    create_backlog(2)

    get transactions_category_suggestions_url

    assert_response :success
    assert_match I18n.t("transactions.category_suggestions.index.no_provider"), response.body
    assert_select "button", text: I18n.t("transactions.category_suggestions.index.suggest"), count: 0
  end

  test "index with an empty backlog says so and offers no button" do
    get transactions_category_suggestions_url

    assert_response :success
    assert_match I18n.t("transactions.category_suggestions.index.empty_title"), response.body
    assert_select "button", text: I18n.t("transactions.category_suggestions.index.suggest"), count: 0
  end

  # create

  test "create asks the provider once for 25 of 26 and renders those rows with the remainder" do
    create_backlog(26)
    sent = nil
    @llm.expects(:auto_categorize).with do |transactions:, **|
      sent = transactions.map { |t| t[:id] }
      true
    end.returns(provider_success_response([])).once

    post transactions_category_suggestions_url

    assert_equal 25, sent.size
    assert_response :success
  end

  test "create renders one row per suggestion, carrying it in the form, and writes nothing" do
    one = create_transaction(account: @account, name: "Starbucks").transaction
    two = create_transaction(account: @account, name: "Shell").transaction
    stub_answers(AutoCategorization.new(transaction_id: one.id, category_name: @category.name),
                 AutoCategorization.new(transaction_id: two.id, category_name: @other_category.name))

    assert_no_difference "DataEnrichment.count" do
      post transactions_category_suggestions_url
    end

    assert_response :success
    assert_select "input[type=hidden][name$='[transaction_id]']", count: 2
    assert_select "input[type=hidden][name$='[transaction_id]'][value='#{one.id}']", count: 1
    assert_select "input[type=hidden][name$='[category_id]'][value='#{@category.id}']", count: 1
    assert_select "button[name=only]", count: 2
    assert_nil one.reload.category_id
    assert_nil two.reload.category_id
  end

  test "create drops a category the family does not have" do
    txn = create_transaction(account: @account, name: "Starbucks").transaction
    stub_answers(AutoCategorization.new(transaction_id: txn.id, category_name: "Invented by the model"))

    post transactions_category_suggestions_url

    assert_response :success
    assert_select "input[type=hidden][name$='[transaction_id]']", count: 0
    assert_match I18n.t("transactions.category_suggestions.suggestions.none"), response.body
  end

  test "create with no provider explains and never calls anything" do
    Provider::Registry.stubs(:preferred_llm_provider).returns(nil)
    create_backlog(2)
    @llm.expects(:auto_categorize).never

    post transactions_category_suggestions_url

    assert_response :unprocessable_entity
    assert_match I18n.t("transactions.category_suggestions.index.no_provider"), response.body
  end

  test "create reports a provider failure instead of raising" do
    create_backlog(1)
    @llm.expects(:auto_categorize).returns(provider_error_response(Provider::Error.new("upstream exploded")))

    assert_difference "DebugLogEntry.where(message: 'AI category suggestion failed').count", 1 do
      post transactions_category_suggestions_url
    end

    assert_response :unprocessable_entity
    assert_match I18n.t("transactions.category_suggestions.suggestions.failed"), response.body
    assert_no_match(/upstream exploded/, response.body)
  end

  test "the make-this-a-rule link prefills a rule matching the suggestion" do
    txn = create_transaction(account: @account, name: "Starbucks").transaction
    stub_answers(AutoCategorization.new(transaction_id: txn.id, category_name: @category.name))
    post transactions_category_suggestions_url

    link = css_select("a").find { |a| a.text.strip == I18n.t("transactions.category_suggestions.suggestions.make_rule") }
    assert link, "each row offers a make-this-a-rule link"
    assert_equal new_rule_path(name: "Starbucks", action_type: "set_transaction_category", action_value: @category.id),
                 link["href"]

    get link["href"]

    assert_response :success
    assert_select "input[name='rule[name]'][value='Starbucks']"
    assert_select "select[name*='[condition_type]'] option[selected][value='transaction_name']"
    assert_select "input[name*='[value]'][value='Starbucks']"
    assert_select "select[name*='[action_type]'] option[selected][value='set_transaction_category']"
    assert_select "select[name*='[value]'] option[selected][value='#{@category.id}']"
  end

  # accept

  test "accept-all applies every posted row and the count equals the rows posted" do
    txns = Array.new(3) { |i| create_transaction(account: @account, name: "Row #{i}").transaction }

    assert_difference -> { Transaction.where(id: txns.map(&:id)).where.not(category_id: nil).count }, 3 do
      post accept_transactions_category_suggestions_url, params: { suggestions: rows_for(txns, @category) }
    end

    assert_redirected_to transactions_category_suggestions_path
    assert_equal I18n.t("transactions.category_suggestions.accept.applied", count: 3), flash[:notice]
    assert_nil flash[:alert]
  end

  test "accepting one row applies only that row" do
    one = create_transaction(account: @account, name: "One").transaction
    two = create_transaction(account: @account, name: "Two").transaction

    assert_difference -> { Transaction.where(id: [ one.id, two.id ]).where.not(category_id: nil).count }, 1 do
      post accept_transactions_category_suggestions_url,
           params: { only: two.id, suggestions: rows_for([ one, two ], @category) }
    end

    assert_nil one.reload.category_id
    assert_equal @category.id, two.reload.category_id
    assert_equal I18n.t("transactions.category_suggestions.accept.applied", count: 1), flash[:notice]
  end

  test "accepted rows are enriched as ai and locked" do
    txn = create_transaction(account: @account, name: "One").transaction

    post accept_transactions_category_suggestions_url, params: { suggestions: rows_for([ txn ], @category) }

    txn.reload
    assert txn.locked?(:category_id)
    assert_equal "ai", txn.data_enrichments.find_by!(attribute_name: "category_id").source
  end

  test "accept skips a row categorised meanwhile and does not overwrite it" do
    meanwhile = create_transaction(account: @account, name: "Meanwhile").transaction
    open_txn = create_transaction(account: @account, name: "Open").transaction
    meanwhile.update!(category: @other_category)

    post accept_transactions_category_suggestions_url, params: { suggestions: rows_for([ meanwhile, open_txn ], @category) }

    assert_equal @other_category.id, meanwhile.reload.category_id
    assert_equal @category.id, open_txn.reload.category_id
    assert_equal I18n.t("transactions.category_suggestions.accept.applied", count: 1), flash[:notice]
    assert_equal I18n.t("transactions.category_suggestions.accept.skipped", count: 1), flash[:alert]
  end

  test "accept rejects a transaction from another family" do
    foreign_account = families(:empty).accounts.create!(name: "Foreign", balance: 0, currency: "USD", accountable: Depository.new)
    foreign = create_transaction(account: foreign_account, name: "Foreign").transaction

    assert_no_difference "DataEnrichment.count" do
      post accept_transactions_category_suggestions_url, params: { suggestions: rows_for([ foreign ], @category) }
    end

    assert_nil foreign.reload.category_id
    assert_nil flash[:notice]
    assert_equal I18n.t("transactions.category_suggestions.accept.skipped", count: 1), flash[:alert]
  end

  test "accept with nothing posted, or malformed params, changes nothing and does not raise" do
    assert_no_difference "DataEnrichment.count" do
      post accept_transactions_category_suggestions_url
      assert_redirected_to transactions_category_suggestions_path
      assert_equal I18n.t("transactions.category_suggestions.accept.none_selected"), flash[:alert]

      post accept_transactions_category_suggestions_url, params: { suggestions: "garbage" }
      assert_redirected_to transactions_category_suggestions_path
    end
  end

  private
    def create_backlog(count)
      Array.new(count) { |i| create_transaction(account: @account, name: "Backlog #{i}", date: i.days.ago.to_date).transaction }
    end

    def stub_answers(*answers)
      @llm.expects(:auto_categorize).returns(provider_success_response(answers)).once
    end

    def rows_for(transactions, category)
      transactions.each_with_index.to_h { |t, i| [ i.to_s, { transaction_id: t.id, category_id: category.id } ] }
    end
end
