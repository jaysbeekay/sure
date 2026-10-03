require "test_helper"

# #130, 11.2. The fixture dates are fixed in 2020 and every transaction here
# lives in a family of its own, so nothing from the shared fixtures can land in
# an event and make an assertion pass for the wrong reason.
class EventTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:empty)
    @checking = @family.accounts.create! name: "Checking", currency: "USD", balance: 5000, accountable: Depository.new
    @food = @family.categories.create! name: "Food"
    @transport = @family.categories.create! name: "Transport"

    # Five inclusive days: day 0 is the 10th, day 4 the 14th.
    @day0 = Date.new(2020, 3, 10)
    @event = @family.events.create! name: "Bali trip", start_date: @day0, end_date: @day0 + 4
  end

  # Boundaries -----------------------------------------------------------

  test "a five day event attributes exactly the transactions dated inside the inclusive range" do
    before_day = txn(-1)
    first_day = txn(0)
    last_day = txn(4)
    after_day = txn(5)

    assert_equal [ first_day, last_day ].sort, @event.transactions.pluck(:id).sort
    assert_not_includes @event.transactions.pluck(:id), before_day
    assert_not_includes @event.transactions.pluck(:id), after_day
  end

  test "a one day event holds that day and nothing around it" do
    event = @family.events.create! name: "Concert", start_date: @day0 + 2, end_date: @day0 + 2
    day_before = txn(1)
    on_the_day = txn(2)
    day_after = txn(3)

    assert_equal [ on_the_day ], event.transactions.pluck(:id)
    assert_not_includes event.transactions.pluck(:id), day_before
    assert_not_includes event.transactions.pluck(:id), day_after
  end

  # Manual overrides -----------------------------------------------------

  test "an included override pulls in a transaction dated outside the range" do
    inside = txn(2)
    outside = txn(5)

    before = @event.transactions.pluck(:id)
    @event.event_transactions.create!(transaction_record: Transaction.find(outside), inclusion: "included")
    after = @event.transactions.pluck(:id)

    assert_equal [ inside ], before
    assert_equal [ outside ], after - before
    assert_empty before - after
  end

  test "an excluded override removes a transaction dated inside the range" do
    keep = txn(1)
    drop = txn(3)

    before = @event.transactions.pluck(:id)
    @event.event_transactions.create!(transaction_record: Transaction.find(drop), inclusion: "excluded")
    after = @event.transactions.pluck(:id)

    assert_equal [ keep, drop ].sort, before.sort
    assert_equal [ drop ], before - after
    assert_empty after - before
  end

  test "an override belongs to its event alone" do
    other = @family.events.create! name: "Other", start_date: @day0, end_date: @day0 + 4
    drop = txn(3)

    @event.event_transactions.create!(transaction_record: Transaction.find(drop), inclusion: "excluded")

    assert_not_includes @event.transactions.pluck(:id), drop
    assert_includes other.transactions.pluck(:id), drop
  end

  test "overlapping events both include a transaction in their shared days" do
    overlap = @family.events.create! name: "Overlap", start_date: @day0 + 3, end_date: @day0 + 8
    shared = txn(4)
    only_first = txn(1)
    only_second = txn(7)

    assert_equal [ only_first, shared ].sort, @event.transactions.pluck(:id).sort
    assert_equal [ shared, only_second ].sort, overlap.transactions.pluck(:id).sort
  end

  # True cost ------------------------------------------------------------

  test "true cost is expenses minus refunds, not the gross sum" do
    txn(0, amount: 100)
    txn(2, amount: 50)
    txn(2, amount: -30, name: "Refund")

    gross = 150

    assert_equal Money.new(120, "USD"), @event.true_cost
    assert_not_equal Money.new(gross, "USD"), @event.true_cost
  end

  test "true cost changes by the refund when a refund is added" do
    txn(0, amount: 100)
    before = @event.true_cost

    txn(2, amount: -30, name: "Refund")

    assert_equal Money.new(-30, "USD"), @event.true_cost - before
  end

  test "an empty event costs nothing" do
    assert_equal Money.new(0, "USD"), @event.true_cost
    assert_empty @event.category_breakdown
  end

  test "true cost follows the manual overrides" do
    txn(1, amount: 40)
    outside = txn(5, amount: 25)
    dropped = txn(2, amount: 10)
    before = @event.true_cost

    @event.event_transactions.create!(transaction_record: Transaction.find(outside), inclusion: "included")
    @event.event_transactions.create!(transaction_record: Transaction.find(dropped), inclusion: "excluded")

    assert_equal Money.new(25 - 10, "USD"), @event.true_cost - before
  end

  test "true cost is in the family currency" do
    @family.update!(currency: "EUR")
    eur = @family.accounts.create! name: "Euro", currency: "EUR", balance: 0, accountable: Depository.new
    usd = @family.accounts.create! name: "Dollar", currency: "USD", balance: 0, accountable: Depository.new
    ExchangeRate.create!(date: @day0 + 1, from_currency: "USD", to_currency: "EUR", rate: 0.5)

    create_transaction(account: eur, date: @day0 + 1, amount: 10, currency: "EUR", name: "In euro")
    create_transaction(account: usd, date: @day0 + 1, amount: 100, currency: "USD", name: "In dollars")

    assert_equal Money.new(60, "EUR"), @event.true_cost
    assert_equal Money.new(60, "EUR"), @event.daily_series.sum(&:amount)
  end

  # What does not count --------------------------------------------------

  test "transfers do not count towards the event" do
    txn(1, amount: 40)
    savings = @family.accounts.create! name: "Savings", currency: "USD", balance: 0, accountable: Depository.new
    before_cost = @event.true_cost
    before_ids = @event.transactions.pluck(:id)

    create_transfer(from_account: @checking, to_account: savings, amount: 500, date: @day0 + 1)

    assert_equal Money.new(0, "USD"), @event.true_cost - before_cost
    assert_equal before_ids, @event.transactions.pluck(:id)
  end

  test "excluded entries do not count towards the event" do
    entry = Entry.find(txn_entry_id(txn(1, amount: 40)))
    before_cost = @event.true_cost
    before_ids = @event.transactions.pluck(:id)

    entry.update!(excluded: true)

    assert_equal Money.new(-40, "USD"), @event.true_cost - before_cost
    assert_equal 1, before_ids.size
    assert_empty @event.transactions.pluck(:id)
  end

  test "accounts excluded from reports do not count towards the event" do
    txn(1, amount: 40)
    hidden = @family.accounts.create! name: "Hidden", currency: "USD", balance: 0, accountable: Depository.new, exclude_from_reports: true
    before_cost = @event.true_cost
    before_ids = @event.transactions.pluck(:id)

    create_transaction(account: hidden, date: @day0 + 1, amount: 75, name: "Hidden spend")

    assert_equal Money.new(0, "USD"), @event.true_cost - before_cost
    assert_equal before_ids, @event.transactions.pluck(:id)
  end

  test "pending transactions do not count towards the event" do
    txn(1, amount: 40)
    before_cost = @event.true_cost

    pending = create_transaction(account: @checking, date: @day0 + 1, amount: 75, name: "Pending")
    pending.entryable.update!(extra: { "plaid" => { "pending" => true } })

    assert_equal Money.new(0, "USD"), @event.true_cost - before_cost
  end

  test "a manual include of a transfer still does not count" do
    savings = @family.accounts.create! name: "Savings", currency: "USD", balance: 0, accountable: Depository.new
    create_transfer(from_account: @checking, to_account: savings, amount: 500, date: @day0 + 9)
    transfer_leg = @checking.transactions.find_by!(kind: "funds_movement")
    before = @event.true_cost

    @event.event_transactions.create!(transaction_record: transfer_leg, inclusion: "included")

    assert_equal Money.new(0, "USD"), @event.true_cost - before
    assert_not_includes @event.transactions.pluck(:id), transfer_leg.id
  end

  test "internal investment movements do not count towards the event" do
    txn(1, amount: 40)
    sweep = Transaction.find(txn(2, amount: 90))
    before_cost = @event.true_cost
    before_ids = @event.transactions.pluck(:id)
    assert_includes before_ids, sweep.id

    sweep.update_columns(investment_activity_label: "Sweep In")

    assert_equal Money.new(-90, "USD"), @event.true_cost - before_cost
    assert_equal [ sweep.id ], before_ids - @event.transactions.pluck(:id)
  end

  test "the transaction list and the true cost agree" do
    txn(0, amount: 100)
    txn(2, amount: -30, name: "Refund")
    txn(4, amount: 12.5)

    signed_sum = @event.transactions.sum { |t| t.entry.amount }

    assert_equal 3, @event.transactions.count
    assert_equal Money.new(signed_sum, "USD"), @event.true_cost
  end

  # Category breakdown ---------------------------------------------------

  test "the category breakdown nets refunds within each category" do
    txn(0, amount: 100, category: @food)
    txn(1, amount: -30, category: @food, name: "Refund")
    txn(2, amount: 50, category: @transport)

    breakdown = @event.category_breakdown.index_by { |row| row.category.name }

    assert_equal Money.new(70, "USD"), breakdown["Food"].total
    assert_equal Money.new(50, "USD"), breakdown["Transport"].total
    assert_in_delta 100.0, @event.category_breakdown.sum(&:weight), 0.001
    assert_equal %w[Food Transport], @event.category_breakdown.map { |row| row.category.name }
  end

  test "an uncategorised transaction is reported as uncategorised" do
    txn(1, amount: 20)

    assert_equal [ "Uncategorized" ], @event.category_breakdown.map { |row| row.category.name }
  end

  test "a subcategory rolls up into its parent" do
    groceries = @family.categories.create! name: "Groceries", parent: @food
    txn(0, amount: 30, category: groceries)
    txn(1, amount: 20, category: @food)

    breakdown = @event.category_breakdown

    assert_equal [ "Food" ], breakdown.map { |row| row.category.name }
    assert_equal Money.new(50, "USD"), breakdown.first.total
  end

  # Daily series ---------------------------------------------------------

  test "the daily series sums to the true cost" do
    txn(0, amount: 100)
    txn(2, amount: 50)
    txn(2, amount: -30, name: "Refund")
    txn(4, amount: 7)

    assert_equal Money.new(127, "USD"), @event.true_cost
    assert_equal @event.true_cost, @event.daily_series.sum(&:amount)
  end

  test "the daily series has one row per day, nets a refund on its own day, and zero-fills" do
    txn(0, amount: 100)
    txn(2, amount: 50)
    txn(2, amount: -30, name: "Refund")

    series = @event.daily_series

    assert_equal (@day0..@day0 + 4).to_a, series.map(&:date)
    assert_equal [ 100, 0, 20, 0, 0 ].map { |n| Money.new(n, "USD") }, series.map(&:amount)
  end

  test "the daily series reaches a manually included day outside the range" do
    txn(1, amount: 40)
    outside = txn(7, amount: 25)
    before = @event.daily_series

    @event.event_transactions.create!(transaction_record: Transaction.find(outside), inclusion: "included")
    after = @event.daily_series

    assert_equal 5, before.size
    assert_equal (@day0..@day0 + 7).to_a, after.map(&:date)
    assert_equal @event.true_cost, after.sum(&:amount)
    assert_equal Money.new(25, "USD"), after.last.amount
  end

  test "the cumulative series ends on the true cost" do
    txn(0, amount: 100)
    txn(2, amount: -30, name: "Refund")

    series = @event.cumulative_series

    assert_equal 5, series.values.size
    assert_equal @event.true_cost, series.values.last.value
    assert_equal Money.new(100, "USD"), series.values.first.value
  end

  test "a one day event has no cumulative series to draw" do
    event = @family.events.create! name: "Concert", start_date: @day0, end_date: @day0

    assert_nil event.cumulative_series
  end

  # Setting overrides ----------------------------------------------------

  test "including a transaction twice keeps one override" do
    outside = Transaction.find(txn(6))

    assert_difference "@event.event_transactions.count", 1 do
      @event.include_transaction!(outside)
      @event.include_transaction!(outside)
    end
    assert_includes @event.transactions.pluck(:id), outside.id
  end

  test "resetting a transaction removes its override and restores the date rule" do
    inside = Transaction.find(txn(2))
    @event.exclude_transaction!(inside)
    before = @event.transactions.pluck(:id)

    assert_difference "@event.event_transactions.count", -1 do
      @event.reset_transaction!(inside)
    end
    assert_equal [ inside.id ], @event.transactions.pluck(:id) - before
  end

  test "resetting a transaction with no override does nothing" do
    inside = Transaction.find(txn(2))

    assert_no_difference "EventTransaction.count" do
      @event.reset_transaction!(inside)
    end
  end

  test "overrides are kept per event" do
    other = @family.events.create! name: "Other", start_date: @day0, end_date: @day0 + 4
    inside = Transaction.find(txn(2))

    @event.exclude_transaction!(inside)
    other.reset_transaction!(inside)

    assert_equal 1, @event.event_transactions.count
  end

  # Candidates to add ----------------------------------------------------

  test "nearby transactions are those just outside the range that the event does not hold" do
    first_day = txn(0)
    last_day = txn(4)
    just_before = txn(-1)
    just_after = txn(5)
    window_start = txn(-14)
    window_end = txn(18)
    before_window = txn(-15)
    after_window = txn(19)

    ids = @event.nearby_transactions(within: 14).pluck(:id)

    assert_equal [ just_before, just_after, window_start, window_end ].sort, ids.sort
    assert_not_includes ids, first_day
    assert_not_includes ids, last_day
    assert_not_includes ids, before_window
    assert_not_includes ids, after_window
  end

  test "a transaction already pulled in is no longer a candidate" do
    candidate = Transaction.find(txn(5))
    before = @event.nearby_transactions(within: 14).pluck(:id)

    @event.include_transaction!(candidate)

    assert_equal [ candidate.id ], before - @event.nearby_transactions(within: 14).pluck(:id)
  end

  test "nearby transactions leave out transfers" do
    savings = @family.accounts.create! name: "Savings", currency: "USD", balance: 0, accountable: Depository.new
    create_transfer(from_account: @checking, to_account: savings, amount: 500, date: @day0 + 6)
    before = @event.nearby_transactions(within: 14).count

    txn(6)

    assert_equal 1, @event.nearby_transactions(within: 14).count - before
    assert_equal 0, before
  end

  # Account access -------------------------------------------------------

  test "scoping to a user leaves out accounts that user cannot see" do
    admin = users(:family_admin)
    private_account = Account.create!(family: families(:dylan_family), owner: admin, name: "Private", currency: "USD", balance: 0, accountable: Depository.new)
    event = families(:dylan_family).events.create!(name: "Private test", start_date: @day0, end_date: @day0 + 4)
    create_transaction(account: private_account, date: @day0 + 1, amount: 60, name: "Private spend")
    member = users(:family_member)

    assert_equal Money.new(60, "USD"), event.true_cost(user: admin)
    assert_equal Money.new(0, "USD"), event.true_cost(user: member)
    assert_empty event.transactions(user: member).pluck(:id)
    assert_equal 1, event.transactions(user: admin).count
    assert_empty event.daily_series(user: member).reject { |day| day.amount.zero? }
    assert_empty event.category_breakdown(user: member)
  end

  # Validation -----------------------------------------------------------

  test "an event whose start is after its end is invalid" do
    event = @family.events.new(name: "Backwards", start_date: @day0 + 3, end_date: @day0)

    assert_no_difference "Event.count" do
      assert_not event.save
    end
    assert_includes event.errors[:end_date], I18n.t("activerecord.errors.models.event.attributes.end_date.before_start")
  end

  test "a one day event is valid" do
    assert @family.events.new(name: "One day", start_date: @day0, end_date: @day0).valid?
  end

  test "the database refuses an end before the start even when validations are skipped" do
    event = @family.events.new(name: "Backwards", start_date: @day0 + 3, end_date: @day0)

    assert_raises(ActiveRecord::CheckViolation) { event.save!(validate: false) }
  end

  test "name and both dates are required" do
    event = @family.events.new

    assert_not event.valid?
    assert event.errors[:name].any?
    assert event.errors[:start_date].any?
    assert event.errors[:end_date].any?
  end

  test "the colour must be a six digit hex" do
    assert_not @family.events.new(name: "X", start_date: @day0, end_date: @day0, color: "red").valid?
    assert_not @family.events.new(name: "X", start_date: @day0, end_date: @day0, color: "#12345").valid?
    assert @family.events.new(name: "X", start_date: @day0, end_date: @day0, color: "#A1b2C3").valid?
  end

  test "a new event takes one of the palette colours by default" do
    assert_includes Event::COLORS, @family.events.new.color
  end

  test "destroying a family destroys its events and their overrides" do
    # A fresh family: the fixture families have users that block their own destruction.
    doomed = Family.create!(name: "Doomed", currency: "USD")
    account = doomed.accounts.create!(name: "Checking", currency: "USD", balance: 0, accountable: Depository.new)
    event = doomed.events.create!(name: "Trip", start_date: @day0, end_date: @day0 + 4)
    outside = create_transaction(account: account, date: @day0 + 9, amount: 10).entryable
    event.event_transactions.create!(transaction_record: outside, inclusion: "included")

    assert_difference [ "Event.count", "EventTransaction.count" ], -1 do
      doomed.destroy!
    end
  end

  # An override exists only where it changes what the date rule would say; otherwise a
  # later change to the event's dates would find a row that no longer means anything.
  test "including a transaction the dates already hold writes no override" do
    inside = Transaction.find(txn(2))

    assert_no_difference "EventTransaction.count" do
      @event.include_transaction!(inside)
    end
    assert_includes @event.transactions.pluck(:id), inside.id
  end

  test "including a transaction that was removed by hand drops the removal" do
    inside = Transaction.find(txn(2))
    @event.exclude_transaction!(inside)

    assert_difference "EventTransaction.count", -1 do
      @event.include_transaction!(inside)
    end
    assert_includes @event.transactions.pluck(:id), inside.id
  end

  test "excluding a transaction the dates already leave out writes no override" do
    outside = Transaction.find(txn(8))

    assert_no_difference "EventTransaction.count" do
      @event.exclude_transaction!(outside)
    end
    assert_not_includes @event.transactions.pluck(:id), outside.id
  end

  test "excluding a transaction that was added by hand drops the addition" do
    outside = Transaction.find(txn(8))
    @event.include_transaction!(outside)

    assert_difference "EventTransaction.count", -1 do
      @event.exclude_transaction!(outside)
    end
    assert_not_includes @event.transactions.pluck(:id), outside.id
  end

  # Two simultaneous POSTs for one pair both pass the Ruby uniqueness check; the loser
  # hits the unique index. It reads the winner's row and updates it instead of raising.
  test "an override that loses a race for the unique index is retried, not raised" do
    outside = Transaction.find(txn(7))
    EventTransaction.any_instance.stubs(:update!).raises(ActiveRecord::RecordNotUnique.new("dup")).then.returns(true)

    assert_nothing_raised { @event.include_transaction!(outside) }
  end

  test "a unique violation that persists is raised after one retry" do
    outside = Transaction.find(txn(7))
    EventTransaction.any_instance.expects(:update!).raises(ActiveRecord::RecordNotUnique.new("dup")).twice

    assert_raises(ActiveRecord::RecordNotUnique) { @event.include_transaction!(outside) }
  end

  test "family has many events" do
    assert_includes @family.events, @event
    assert_not_includes families(:dylan_family).events, @event
  end

  private
    # Creates an expense on the given day (an offset from day 0) and returns
    # the transaction id.
    def txn(offset, amount: 10, name: "Spend", category: nil)
      create_transaction(account: @checking, date: @day0 + offset, amount: amount, name: name, category: category).entryable.id
    end

    def txn_entry_id(transaction_id)
      Transaction.find(transaction_id).entry.id
    end
end
