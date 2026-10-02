require "test_helper"

class Family::CategorySuggestionReviewTest < ActiveSupport::TestCase
  include EntriesTestHelper, ProviderTestHelper

  AutoCategorization = Provider::LlmConcept::AutoCategorization

  setup do
    @user = users(:family_admin)
    @family = @user.family
    @family.accounts.each { |a| a.entries.delete_all }
    @account = accounts(:depository)
    @category = categories(:food_and_drink)
    @other_category = categories(:income)
    @review = Family::CategorySuggestionReview.new(@family, user: @user)
    @llm_provider = mock
    Provider::Registry.stubs(:preferred_llm_provider).returns(@llm_provider)
  end

  # backlog

  test "backlog counts only uncategorised, unlocked transactions on accounts the user can annotate" do
    base = @review.backlog_count

    create_transaction(account: @account, name: "Open")
    assert_equal base + 1, @review.backlog_count, "an uncategorised transaction is counted"

    create_transaction(account: @account, name: "Categorised", category: @category)
    assert_equal base + 1, @review.backlog_count, "a categorised transaction is not"

    create_transaction(account: @account, name: "Locked").transaction.lock_attr!(:category_id)
    assert_equal base + 1, @review.backlog_count, "a transaction whose category is locked cannot be suggested for, so is not counted"

    create_transaction(account: @account, name: "Excluded", excluded: true)
    assert_equal base + 1, @review.backlog_count, "an excluded entry is not"

    foreign_account = families(:empty).accounts.create!(name: "Foreign", balance: 0, currency: "USD", accountable: Depository.new)
    create_transaction(account: foreign_account, name: "Foreign")
    assert_equal base + 1, @review.backlog_count, "another family's transaction is not"
  end

  test "backlog leaves out an account the user can only read" do
    member = users(:family_member)
    review = Family::CategorySuggestionReview.new(@family, user: member)
    accounts(:credit_card).entries.delete_all
    base = review.backlog_count

    create_transaction(account: accounts(:credit_card), name: "On a read-only share")
    assert_equal base, review.backlog_count

    create_transaction(account: accounts(:depository), name: "On a full-control share")
    assert_equal base + 1, review.backlog_count
  end

  # suggest

  test "suggest sends the 25 newest of 26 in one call and reports what is left" do
    backlog = create_backlog(26)
    sent_ids = nil
    @llm_provider.expects(:auto_categorize).with do |transactions:, **|
      sent_ids = transactions.map { |t| t[:id] }
      true
    end.returns(provider_success_response([])).once

    batch = @review.suggest

    assert_equal backlog.first(25).map(&:id).sort, sent_ids.sort, "the oldest (26th) transaction waits for the next batch"
    assert_equal 1, batch.remaining
  end

  test "suggest with exactly 25 in the backlog leaves nothing remaining" do
    create_backlog(25)
    @llm_provider.expects(:auto_categorize).returns(provider_success_response([])).once

    assert_equal 0, @review.suggest.remaining
  end

  test "suggest returns the pairs and writes nothing" do
    entry = create_transaction(account: @account, name: "Coffee")
    txn = entry.transaction
    @llm_provider.expects(:auto_categorize).returns(provider_success_response([
      AutoCategorization.new(transaction_id: txn.id, category_name: @category.name)
    ]))

    assert_no_difference "DataEnrichment.count" do
      batch = @review.suggest
      assert_equal [ [ txn, @category ] ], batch.pairs
    end
    assert_nil txn.reload.category_id
    assert_not txn.locked?(:category_id)
  end

  test "suggest with an empty backlog never calls the provider" do
    @llm_provider.expects(:auto_categorize).never

    batch = @review.suggest

    assert_empty batch.pairs
    assert_equal 0, batch.remaining
  end

  test "suggest with no provider raises before any call" do
    Provider::Registry.stubs(:preferred_llm_provider).returns(nil)
    create_transaction(account: @account, name: "Coffee")

    assert_raises(Family::AutoCategorizer::Error) { @review.suggest }
  end

  # accept

  # Provenance: a row is applied only with the token `suggest` signed for that exact pair,
  # so an edited or replayed form cannot record another category as the AI's answer.
  test "accept skips a row posted without the token the suggestion was signed with" do
    txn = create_transaction(account: @account, name: "Unsigned").transaction

    result = @review.accept([ { transaction_id: txn.id, category_id: @category.id } ])

    assert_equal 0, result.applied
    assert_equal 1, result.skipped
    assert_nil txn.reload.category_id
  end

  test "accept skips a row whose category was changed after the suggestion was signed" do
    txn = create_transaction(account: @account, name: "Edited").transaction
    row = signed(txn, @category).merge(category_id: @other_category.id)

    result = @review.accept([ row ])

    assert_equal 0, result.applied
    assert_nil txn.reload.category_id
  end

  test "accept skips a token signed for another transaction" do
    one = create_transaction(account: @account, name: "One").transaction
    two = create_transaction(account: @account, name: "Two").transaction
    row = { transaction_id: two.id, category_id: @category.id, token: @review.token_for(one.id, @category.id) }

    assert_equal 0, @review.accept([ row ]).applied
    assert_nil two.reload.category_id
  end

  test "accept skips a token signed for another user" do
    txn = create_transaction(account: @account, name: "Other user").transaction
    other = Family::CategorySuggestionReview.new(@family, user: users(:family_member))

    result = @review.accept([ signed(txn, @category, review: other) ])

    assert_equal 0, result.applied
  end

  test "accept skips a token that has expired" do
    txn = create_transaction(account: @account, name: "Old").transaction
    row = signed(txn, @category)

    travel(Family::CategorySuggestionReview::TOKEN_LIFETIME + 1.minute) do
      assert_equal 0, @review.accept([ row ]).applied
    end
    assert_equal 1, @review.accept([ row ]).applied
  end

  test "an exception on one row skips that row, logs it, and the others still apply" do
    bad = create_transaction(account: @account, name: "Bad").transaction
    good = create_transaction(account: @account, name: "Good").transaction
    Transaction.any_instance.stubs(:enrich_attribute).with { |*| true }.raises(ActiveRecord::StatementInvalid.new("boom")).then.returns(true)

    assert_difference "DebugLogEntry.where(category: 'category_suggestions', level: 'error').count", 1 do
      result = @review.accept([ signed(bad, @category), signed(good, @category) ])

      assert_equal 1, result.applied
      assert_equal 1, result.skipped
    end
  end

  test "accept applies only the posted rows" do
    posted = create_transaction(account: @account, name: "Posted").transaction
    left_alone = create_transaction(account: @account, name: "Left alone").transaction

    result = @review.accept([ signed(posted, @category) ])

    assert_equal 1, result.applied
    assert_equal @category.id, posted.reload.category_id
    assert_nil left_alone.reload.category_id
  end

  test "accept enriches as ai, locks the category and records the value the cache check compares" do
    txn = create_transaction(account: @account, name: "Posted").transaction

    assert_difference "DataEnrichment.where(source: 'ai', attribute_name: 'category_id').count", 1 do
      @review.accept([ signed(txn, @category) ])
    end

    txn.reload
    assert txn.locked?(:category_id)
    assert_equal @category.id, txn.data_enrichments.find_by!(attribute_name: "category_id", source: "ai").value
  end

  test "accept skips a row categorised since the suggestion, and does not overwrite it" do
    meanwhile = create_transaction(account: @account, name: "Categorised meanwhile").transaction
    still_open = create_transaction(account: @account, name: "Still open").transaction
    meanwhile.update!(category: @other_category)

    result = @review.accept([
      signed(meanwhile, @category),
      signed(still_open, @category)
    ])

    assert_equal 1, result.applied
    assert_equal 1, result.skipped
    assert_equal @other_category.id, meanwhile.reload.category_id
    assert_not meanwhile.locked?(:category_id)
    assert_equal @category.id, still_open.reload.category_id
  end

  # The race the row lock closes: the eligibility query ran, then someone
  # categorised the row before the write. Simulated by making the query stale.
  test "accept re-checks under the row lock when the eligibility query was stale" do
    txn = create_transaction(account: @account, name: "Raced").transaction
    txn.update!(category: @other_category)
    @review.stubs(:backlog_transaction_ids_among).returns([ txn.id ])

    result = @review.accept([ signed(txn, @category) ])

    assert_equal 0, result.applied
    assert_equal 1, result.skipped
    assert_equal @other_category.id, txn.reload.category_id
    assert_not txn.locked?(:category_id)
  end

  test "accept skips a row whose category was locked since the suggestion" do
    txn = create_transaction(account: @account, name: "Locked meanwhile").transaction
    txn.lock_attr!(:category_id)

    result = @review.accept([ signed(txn, @category) ])

    assert_equal 0, result.applied
    assert_equal 1, result.skipped
    assert_nil txn.reload.category_id
  end

  test "accept rejects a transaction from another family" do
    foreign_account = families(:empty).accounts.create!(name: "Foreign", balance: 0, currency: "USD", accountable: Depository.new)
    foreign = create_transaction(account: foreign_account, name: "Foreign").transaction

    assert_no_difference "DataEnrichment.count" do
      result = @review.accept([ signed(foreign, @category) ])
      assert_equal 0, result.applied
      assert_equal 1, result.skipped
    end
    assert_nil foreign.reload.category_id
  end

  test "accept rejects a category from another family" do
    txn = create_transaction(account: @account, name: "Posted").transaction
    foreign_category = families(:empty).categories.create!(name: "Foreign category", color: "#123456", lucide_icon: "shapes")

    result = @review.accept([ signed(txn, foreign_category) ])

    assert_equal 0, result.applied
    assert_equal 1, result.skipped
    assert_nil txn.reload.category_id
  end

  test "accept on an account the user can only read applies nothing" do
    review = Family::CategorySuggestionReview.new(@family, user: users(:family_member))
    txn = create_transaction(account: accounts(:credit_card), name: "Read-only share").transaction

    result = review.accept([ signed(txn, @category) ])

    assert_equal 0, result.applied
    assert_nil txn.reload.category_id
  end

  test "accept ignores malformed rows and duplicates without raising" do
    txn = create_transaction(account: @account, name: "Posted").transaction

    result = @review.accept([
      signed(txn, @category),
      signed(txn, @category),
      signed("not-a-uuid", @category),
      { transaction_id: nil, category_id: nil }
    ])

    assert_equal 1, result.applied
    assert_equal @category.id, txn.reload.category_id
  end

  # Active Record casts a malformed uuid to nil before the query reaches Postgres, so
  # neither id can raise; pinned for both columns, alone and beside a valid row.
  test "accept treats a malformed transaction or category id as a skipped row, not an error" do
    txn = create_transaction(account: @account, name: "Valid").transaction
    other = create_transaction(account: @account, name: "Other").transaction

    result = nil
    assert_nothing_raised do
      result = @review.accept([
        signed(txn, "not-a-uuid"),
        signed("also-bad", @category),
        signed(other, @category)
      ])
    end

    assert_equal 1, result.applied
    assert_equal 2, result.skipped
    assert_nil txn.reload.category_id
    assert_equal @category.id, other.reload.category_id
  end

  test "accept applied count equals the rows that were actually changed" do
    txns = Array.new(3) { |i| create_transaction(account: @account, name: "Row #{i}").transaction }
    before = Transaction.where(id: txns.map(&:id)).where.not(category_id: nil).count

    result = @review.accept(txns.map { |t| signed(t, @category) })

    after = Transaction.where(id: txns.map(&:id)).where.not(category_id: nil).count
    assert_equal 3, result.applied
    assert_equal result.applied, after - before
  end

  private
    def signed(transaction, category, review: @review)
      transaction_id = transaction.respond_to?(:id) ? transaction.id : transaction
      category_id = category.respond_to?(:id) ? category.id : category
      { transaction_id: transaction_id, category_id: category_id, token: review.token_for(transaction_id, category_id) }
    end
    def create_backlog(count)
      Array.new(count) { |i| create_transaction(account: @account, name: "Backlog #{i}", date: i.days.ago.to_date).transaction }
    end
end
