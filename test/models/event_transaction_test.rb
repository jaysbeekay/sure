require "test_helper"

class EventTransactionTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:empty)
    @checking = @family.accounts.create! name: "Checking", currency: "USD", balance: 0, accountable: Depository.new
    @event = @family.events.create! name: "Trip", start_date: Date.new(2020, 3, 10), end_date: Date.new(2020, 3, 14)
    @transaction = create_transaction(account: @checking, date: Date.new(2020, 3, 20)).entryable
  end

  # The event is what is invalid here (it has no family); the override must report that
  # through validation, not raise from its own family check.
  test "an override on an event with no family does not raise when validated" do
    override = EventTransaction.new(event: Event.new, transaction_record: @transaction, inclusion: "included")

    assert_nothing_raised { override.valid? }
    assert_not override.event.valid?
  end

  test "one override per event and transaction" do
    @event.event_transactions.create!(transaction_record: @transaction, inclusion: "included")

    duplicate = @event.event_transactions.new(transaction_record: @transaction, inclusion: "excluded")

    assert_no_difference "EventTransaction.count" do
      assert_not duplicate.save
    end
    assert duplicate.errors[:transaction_id].any?
  end

  test "the database refuses a second override for the same pair" do
    @event.event_transactions.create!(transaction_record: @transaction, inclusion: "included")

    duplicate = @event.event_transactions.new(transaction_record: @transaction, inclusion: "excluded")

    assert_raises(ActiveRecord::RecordNotUnique) { duplicate.save!(validate: false) }
  end

  test "the same transaction may be overridden on two events" do
    other = @family.events.create! name: "Other", start_date: Date.new(2020, 3, 10), end_date: Date.new(2020, 3, 14)
    @event.event_transactions.create!(transaction_record: @transaction, inclusion: "included")

    assert_difference "EventTransaction.count", 1 do
      other.event_transactions.create!(transaction_record: @transaction, inclusion: "included")
    end
  end

  test "inclusion is included or excluded" do
    assert_not @event.event_transactions.new(transaction_record: @transaction, inclusion: "maybe").valid?
    assert_not @event.event_transactions.new(transaction_record: @transaction, inclusion: nil).valid?
    assert @event.event_transactions.new(transaction_record: @transaction, inclusion: "excluded").valid?
  end

  test "the database refuses an unknown inclusion" do
    override = @event.event_transactions.new(transaction_record: @transaction, inclusion: "maybe")

    assert_raises(ActiveRecord::CheckViolation) { override.save!(validate: false) }
  end

  test "a transaction from another family cannot be attached" do
    foreign = create_transaction(account: accounts(:depository), date: Date.new(2020, 3, 12)).entryable

    override = @event.event_transactions.new(transaction_record: foreign, inclusion: "included")

    assert_no_difference "EventTransaction.count" do
      assert_not override.save
    end
    assert override.errors[:transaction_record].any?
  end

  test "deleting the transaction removes its overrides" do
    @event.event_transactions.create!(transaction_record: @transaction, inclusion: "included")

    assert_difference "EventTransaction.count", -1 do
      @transaction.entry.destroy!
    end
  end
end
