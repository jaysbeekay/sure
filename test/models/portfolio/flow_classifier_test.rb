require "test_helper"

class Portfolio::FlowClassifierTest < ActiveSupport::TestCase
  include PortfolioReturnsTestHelper, EntriesTestHelper

  setup do
    @family = families(:empty)
    @brokerage = create_portfolio_account(family: @family, name: "Brokerage")
    @isa = create_portfolio_account(family: @family, name: "ISA")
    @checking = @family.accounts.create!(
      name: "Checking", balance: 10_000, currency: "USD", accountable: Depository.new
    )
    @date = Date.new(2026, 3, 3)
  end

  # F1 / F4: the same economic event in the two storage shapes the codebase
  # actually writes.
  test "a dividend is income in either storage shape" do
    trade_entry = income_trade(account: @brokerage, date: @date, amount: 50)
    txn_entry = income_transaction(account: @brokerage, date: @date, amount: 50)

    assert_equal :income, classifier.classify(trade_entry)
    assert_equal :income, classifier.classify(txn_entry)
  end

  test "interest is income" do
    entry = income_trade(account: @brokerage, date: @date, amount: 5, label: "Interest")

    assert_equal :income, classifier.classify(entry)
  end

  # F2 / F5.
  test "a fee is classified as a fee" do
    assert_equal :fee, classifier.classify(fee_entry(account: @brokerage, date: @date, amount: 10))
  end

  # F3.
  test "a buy is internal" do
    entry = buy_trade(account: @brokerage, date: @date, qty: 2, price: 100)

    assert_equal :internal, classifier.classify(entry)
  end

  # F8.
  test "an unlabelled transaction is external" do
    assert_equal :external, classifier.classify(deposit(account: @brokerage, date: @date, amount: 500))
  end

  # F9.
  test "an excluded entry is never a flow" do
    entry = deposit(account: @brokerage, date: @date, amount: 500)
    entry.update!(excluded: true)

    assert_equal :internal, classifier.classify(entry)
  end

  # F6 / F7. The same transfer, classified twice against different scopes. This
  # is why the scope is a required argument: a broker-to-broker move is a
  # contribution to one account and invisible to the family.
  test "a transfer is internal to a scope holding both ends and external to one holding a single end" do
    create_transfer(from_account: @isa, to_account: @brokerage, amount: 1_000, date: @date)
    inbound = @brokerage.entries.order(:created_at).last

    both_ends = Portfolio::FlowClassifier.new(scope_account_ids: [ @brokerage.id, @isa.id ])
    one_end = Portfolio::FlowClassifier.new(scope_account_ids: [ @brokerage.id ])

    assert_equal :internal, both_ends.classify(inbound)
    assert_equal :external, one_end.classify(inbound)
  end

  # The reason the classifier joins `transfers` rather than reading
  # Transaction#kind: the leg landing in the investment account is written with
  # kind "funds_movement", and it is the OUTFLOW leg in the funding account that
  # carries "investment_contribution" (Transfer::Creator#outflow_transaction_kind).
  # A rule keyed on `kind` would misread every incoming contribution.
  test "a contribution from outside the scope is external even though its kind is funds_movement" do
    create_transfer(from_account: @checking, to_account: @brokerage, amount: 1_000, date: @date)
    inbound = @brokerage.entries.order(:created_at).last

    assert_equal "funds_movement", inbound.entryable.kind
    assert_equal :external, classifier.classify(inbound)
  end

  # Only the (inflow, outflow) PAIR is uniquely indexed, so the database permits
  # one transaction to be the inflow of one transfer and the outflow of another;
  # the model's two per-column uniqueness validations are bypassed by any writer
  # that skips validation. Joining `transfers` with an OR matched both rows and
  # duplicated the entry, doubling every amount summed from it. The counterpart
  # is resolved through a LATERAL that returns at most one row instead.
  test "a doubly linked transaction is counted once rather than duplicated" do
    create_transfer(from_account: @checking, to_account: @brokerage, amount: 1_000, date: @date)
    inbound = @brokerage.entries.order(:created_at).last

    # Link the same transaction into a second transfer, as an unvalidated writer
    # could. `save(validate: false)` is the point of the test.
    second = Transfer.new(
      inflow_transaction: Transaction.create!(kind: "funds_movement"),
      outflow_transaction: inbound.entryable
    )
    second.save!(validate: false)

    assert_equal 2, Transfer.where(
      "inflow_transaction_id = :id OR outflow_transaction_id = :id", id: inbound.entryable_id
    ).count, "the fixture must really be doubly linked, or this proves nothing"

    rows = ActiveRecord::Base.connection.select_all(
      ActiveRecord::Base.sanitize_sql_array([
        <<~SQL, { entry_ids: [ inbound.id ], scope_account_ids: [ @brokerage.id ] }
          SELECT entries.id, #{Portfolio::FlowClassifier.sql_case(
            entries: "entries", trades: "flow_trades",
            transactions: "flow_transactions", counterpart: "flow_counterpart_entries"
          )} AS flow_class
          FROM entries
          #{Portfolio::FlowClassifier.sql_joins(
            entries: "entries", trades: "flow_trades",
            transactions: "flow_transactions", counterpart: "flow_counterpart_entries"
          )}
          WHERE entries.id = ANY(array[:entry_ids]::uuid[])
        SQL
      ])
    ).to_a

    assert_equal 1, rows.size, "the entry must appear once, or its amount is summed twice"
  end

  # A transaction that is the inflow of one transfer and the outflow of
  # another, as an unvalidated writer can leave it. The Ruby form looks up
  # the inflow link first; the SQL form must reach the same counterpart. The
  # outflow link is written first, so an unordered LIMIT 1 would find it.
  test "a doubly linked transaction resolves to the inflow counterpart in both forms" do
    brokerage_leg = deposit(account: @brokerage, date: @date, amount: 300)
    isa_leg = @isa.entries.create!(
      name: "To brokerage", date: @date, amount: 300, currency: "USD",
      entryable: Transaction.new(kind: "funds_movement")
    )
    checking_leg = @checking.entries.create!(
      name: "To brokerage", date: @date, amount: 300, currency: "USD",
      entryable: Transaction.new(kind: "funds_movement")
    )
    Transfer.new(inflow_transaction: isa_leg.entryable, outflow_transaction: brokerage_leg.entryable).save!(validate: false)
    Transfer.new(inflow_transaction: brokerage_leg.entryable, outflow_transaction: checking_leg.entryable).save!(validate: false)

    scope_ids = [ @brokerage.id, @isa.id ]

    assert_equal :external, Portfolio::FlowClassifier.new(scope_account_ids: scope_ids).classify(brokerage_leg),
                 "the inflow link's counterpart is the checking account, outside the scope"
    assert_equal "external", sql_classifications([ brokerage_leg.id ], scope_ids).fetch(brokerage_leg.id)
  end

  test "rejects an unsafe sql alias" do
    assert_raises Portfolio::FlowClassifier::UnsafeAliasError do
      Portfolio::FlowClassifier.sql_case(entries: "entries; DROP TABLE users --")
    end
  end

  # The design's safety net. Two forms are generated from one rule table so the
  # returns query can classify in SQL while tests classify in Ruby; if they ever
  # disagree, every figure downstream is wrong in a way no other test would
  # catch. Editing one form without the other must fail here.
  test "the ruby and sql forms agree on every rule in the table" do
    corpus = build_corpus

    scope_ids = [ @brokerage.id, @isa.id ]
    ruby_classifier = Portfolio::FlowClassifier.new(scope_account_ids: scope_ids)

    ruby = corpus.to_h { |entry| [ entry.id, ruby_classifier.classify(entry).to_s ] }
    sql = sql_classifications(corpus.map(&:id), scope_ids)

    assert_equal corpus.size, sql.size, "every corpus entry must be classified by the query"

    corpus.each do |entry|
      assert_equal ruby.fetch(entry.id), sql.fetch(entry.id),
                   "#{entry.name.inspect} (#{entry.entryable_type}) classified differently by Ruby and SQL"
    end
  end

  private
    def classifier
      @classifier ||= Portfolio::FlowClassifier.new(scope_account_ids: [ @brokerage.id, @isa.id ])
    end

    # One entry per row of the contract's flow table, plus the two transfer
    # directions and an excluded entry.
    def build_corpus
      entries = []
      entries << income_trade(account: @brokerage, date: @date, amount: 50)                      # F1
      entries << income_trade(account: @brokerage, date: @date, amount: 5, label: "Interest")    # F1
      entries << fee_trade(account: @brokerage, date: @date, amount: 3)                          # F2
      entries << buy_trade(account: @brokerage, date: @date, qty: 2, price: 100)                 # F3
      entries << transfer_trade(account: @brokerage, date: @date)                                # F3
      entries << income_transaction(account: @brokerage, date: @date, amount: 20)                # F4
      entries << fee_entry(account: @brokerage, date: @date, amount: 10)                         # F5
      entries << deposit(account: @brokerage, date: @date, amount: 500)                          # F8

      create_transfer(from_account: @isa, to_account: @brokerage, amount: 1_000, date: @date)    # F6
      entries << @brokerage.entries.order(:created_at).last

      create_transfer(from_account: @checking, to_account: @brokerage, amount: 750, date: @date) # F7
      entries << @brokerage.entries.order(:created_at).last

      excluded = deposit(account: @brokerage, date: @date, amount: 5)                            # F9
      excluded.update!(excluded: true)
      entries << excluded

      # `entries.excluded` is nullable, so NULL is a third state. Ruby reads it
      # as falsy and SQL's bare `excluded = false` evaluates to NULL, which
      # drops the row -- the two must be made to agree, and this is the corpus
      # entry that proves it.
      null_excluded = deposit(account: @brokerage, date: @date, amount: 7)
      null_excluded.update_column(:excluded, nil)
      entries << null_excluded.reload

      entries
    end

    def sql_classifications(entry_ids, scope_ids)
      sql = <<~SQL
        SELECT entries.id AS id, #{Portfolio::FlowClassifier.sql_case(
          entries: "entries", trades: "flow_trades",
          transactions: "flow_transactions", counterpart: "flow_counterpart_entries"
        )} AS flow_class
        FROM entries
        #{Portfolio::FlowClassifier.sql_joins(
          entries: "entries", trades: "flow_trades",
          transactions: "flow_transactions", counterpart: "flow_counterpart_entries"
        )}
        WHERE entries.id = ANY(array[:entry_ids]::uuid[])
      SQL

      ActiveRecord::Base.connection.select_all(
        ActiveRecord::Base.sanitize_sql_array([ sql, { entry_ids: entry_ids, scope_account_ids: scope_ids } ])
      ).to_a.to_h { |row| [ row["id"], row["flow_class"] ] }
    end

    def fee_trade(account:, date:, amount:)
      account.entries.create!(
        name: "Trade fee", date: date, amount: BigDecimal(amount.to_s), currency: account.currency,
        entryable: Trade.new(
          security: security_under_test, qty: 0, price: 0,
          currency: account.currency, investment_activity_label: "Fee"
        )
      )
    end

    def transfer_trade(account:, date:)
      account.entries.create!(
        name: "Security transfer in", date: date, amount: 0, currency: account.currency,
        entryable: Trade.new(
          security: security_under_test, qty: 5, price: 100,
          currency: account.currency, investment_activity_label: "Transfer"
        )
      )
    end
end
