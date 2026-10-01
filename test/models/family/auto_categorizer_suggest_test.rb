require "test_helper"

class Family::AutoCategorizerSuggestTest < ActiveSupport::TestCase
  include EntriesTestHelper, ProviderTestHelper

  AutoCategorization = Provider::LlmConcept::AutoCategorization

  setup do
    @family = families(:dylan_family)
    @account = @family.accounts.create!(name: "Suggest test", balance: 100, currency: "USD", accountable: Depository.new)
    @category = @family.categories.create!(name: "Suggested category")
    @llm_provider = mock
    Provider::Registry.stubs(:preferred_llm_provider).returns(@llm_provider)
  end

  test "returns transaction and category pairs and writes nothing" do
    txn1 = create_transaction(account: @account, name: "McDonalds").transaction
    txn2 = create_transaction(account: @account, name: "Netflix").transaction
    stub_answers(AutoCategorization.new(transaction_id: txn1.id, category_name: @category.name),
                 AutoCategorization.new(transaction_id: txn2.id, category_name: @category.name))

    before = snapshot(txn1, txn2)

    pairs = nil
    assert_no_difference [ "DataEnrichment.count", "DebugLogEntry.count" ] do
      pairs = Family::AutoCategorizer.new(@family, transaction_ids: [ txn1.id, txn2.id ]).suggest
    end

    assert_equal [ [ txn1, @category ], [ txn2, @category ] ].sort_by { |t, _| t.id }, pairs.sort_by { |t, _| t.id }
    assert_equal before, snapshot(txn1, txn2), "category_id, locked_attributes and updated_at must be unchanged"
    assert_nil txn1.reload.category_id
    assert_not txn1.locked?(:category_id)
  end

  test "drops answers naming a category the family does not have, or no category" do
    txn1 = create_transaction(account: @account, name: "One").transaction
    txn2 = create_transaction(account: @account, name: "Two").transaction
    txn3 = create_transaction(account: @account, name: "Three").transaction
    stub_answers(AutoCategorization.new(transaction_id: txn1.id, category_name: "Invented by the model"),
                 AutoCategorization.new(transaction_id: txn2.id, category_name: nil),
                 AutoCategorization.new(transaction_id: txn3.id, category_name: @category.name))

    pairs = Family::AutoCategorizer.new(@family, transaction_ids: [ txn1.id, txn2.id, txn3.id ]).suggest

    assert_equal [ [ txn3, @category ] ], pairs
  end

  test "ignores an answer for a transaction that was not asked about" do
    asked = create_transaction(account: @account, name: "Asked").transaction
    unasked = create_transaction(account: @account, name: "Unasked").transaction
    stub_answers(AutoCategorization.new(transaction_id: unasked.id, category_name: @category.name))

    assert_empty Family::AutoCategorizer.new(@family, transaction_ids: [ asked.id ]).suggest
  end

  test "does not offer a transaction from another family" do
    foreign_account = families(:empty).accounts.create!(name: "Foreign", balance: 0, currency: "USD", accountable: Depository.new)
    foreign = create_transaction(account: foreign_account, name: "Foreign").transaction
    @llm_provider.expects(:auto_categorize).never

    assert_empty Family::AutoCategorizer.new(@family, transaction_ids: [ foreign.id ]).suggest
  end

  test "leaves out a transaction whose category is locked, as the write path does" do
    open_txn = create_transaction(account: @account, name: "Open").transaction
    locked = create_transaction(account: @account, name: "Locked").transaction
    locked.lock_attr!(:category_id)
    sent_ids = nil
    @llm_provider.expects(:auto_categorize).with do |transactions:, **|
      sent_ids = transactions.map { |t| t[:id] }
      true
    end.returns(provider_success_response([]))

    Family::AutoCategorizer.new(@family, transaction_ids: [ open_txn.id, locked.id ]).suggest

    assert_equal [ open_txn.id ], sent_ids
  end

  test "accepts exactly 25 transactions in one provider call" do
    ids = create_transactions(25)
    sent = nil
    @llm_provider.expects(:auto_categorize).with do |transactions:, **|
      sent = transactions.size
      true
    end.returns(provider_success_response([])).once

    Family::AutoCategorizer.new(@family, transaction_ids: ids).suggest

    assert_equal 25, sent
  end

  test "refuses 26 transactions without calling the provider" do
    ids = create_transactions(26)
    @llm_provider.expects(:auto_categorize).never

    error = assert_raises(Family::AutoCategorizer::Error) do
      Family::AutoCategorizer.new(@family, transaction_ids: ids).suggest
    end

    assert_match(/25/, error.message)
  end

  test "raises without calling anything when no provider is configured" do
    Provider::Registry.stubs(:preferred_llm_provider).returns(nil)
    txn = create_transaction(account: @account, name: "Coffee").transaction

    assert_raises(Family::AutoCategorizer::Error) do
      Family::AutoCategorizer.new(@family, transaction_ids: [ txn.id ]).suggest
    end
  end

  test "raises when the family has no categories, without calling the provider" do
    @family.categories.destroy_all
    txn = create_transaction(account: @account, name: "Coffee").transaction
    @llm_provider.expects(:auto_categorize).never

    assert_raises(Family::AutoCategorizer::Error) do
      Family::AutoCategorizer.new(@family, transaction_ids: [ txn.id ]).suggest
    end
  end

  test "records a debug entry and raises when the provider fails" do
    txn = create_transaction(account: @account, name: "Coffee").transaction
    @llm_provider.expects(:auto_categorize)
                 .returns(provider_error_response(Provider::Error.new("upstream exploded")))

    assert_difference "DebugLogEntry.count", 1 do
      error = assert_raises(Family::AutoCategorizer::Error) do
        Family::AutoCategorizer.new(@family, transaction_ids: [ txn.id ]).suggest
      end
      assert_match(/upstream exploded/, error.message)
    end

    entry = DebugLogEntry.order(:created_at).last
    assert_equal "auto_categorization", entry.category
    assert_equal "error", entry.level
    assert_equal @family, entry.family
    assert_equal [ txn.id ], entry.metadata["requested_transaction_ids"]
  end

  test "never asks the shadow provider, even when sampling is on" do
    @family.update!(categorization_shadow_rate: 1.0)
    txn = create_transaction(account: @account, name: "Coffee").transaction
    stub_answers(AutoCategorization.new(transaction_id: txn.id, category_name: @category.name))

    assert_no_difference "CategorizationComparison.count" do
      Family::AutoCategorizer.new(@family, transaction_ids: [ txn.id ]).suggest
    end
  end

  test "withholds a Jev answer below the confidence threshold" do
    @family.update!(categorization_provider: "jev", categorization_confidence_threshold: 0.8)
    low = create_transaction(account: @account, name: "Low").transaction
    high = create_transaction(account: @account, name: "High").transaction
    jev = Provider::Jev.allocate
    Provider::Registry.stubs(:get_provider).with(:jev).returns(jev)
    decision = ->(txn, confidence) do
      Provider::ClassificationConcept::CategoryDecision.new(
        transaction_id: txn.id, category_name: @category.name, confidence: confidence,
        probabilities: {}, usage: {}
      )
    end
    jev.expects(:auto_categorize).returns(provider_success_response([ decision.(low, 0.5), decision.(high, 0.9) ]))

    pairs = Family::AutoCategorizer.new(@family, transaction_ids: [ low.id, high.id ]).suggest

    assert_equal [ [ high, @category ] ], pairs
  end

  private
    def stub_answers(*answers)
      @llm_provider.expects(:auto_categorize).returns(provider_success_response(answers)).once
    end

    def snapshot(*transactions)
      transactions.map do |t|
        t.reload
        [ t.id, t.category_id, t.locked_attributes, t.updated_at ]
      end
    end

    def create_transactions(count)
      Array.new(count) { |i| create_transaction(account: @account, name: "Bulk #{i}").transaction.id }
    end
end
