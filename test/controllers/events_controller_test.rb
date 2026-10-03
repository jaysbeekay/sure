require "test_helper"

class EventsControllerTest < ActionDispatch::IntegrationTest
  include EntriesTestHelper

  setup do
    @user = users(:family_admin)
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => true))
    sign_in @user
    ensure_tailwind_build

    @event = events(:bali_trip)
    @other_event = events(:other_family_trip)
    @account = accounts(:depository)
    @day0 = @event.start_date
  end

  # Preview gate ---------------------------------------------------------

  test "redirects users without preview access" do
    disable_preview

    get events_url
    assert_redirected_to root_path
    assert_match(/preview/i, flash[:alert])

    get event_url(@event)
    assert_redirected_to root_path

    get new_event_url
    assert_redirected_to root_path
  end

  test "the gate stops writes as well as reads" do
    disable_preview
    spend = txn(1)

    assert_no_difference "Event.count" do
      post events_url, params: { event: { name: "Sneaky", start_date: "2020-04-01", end_date: "2020-04-02" } }
    end
    assert_redirected_to root_path

    assert_no_changes -> { @event.reload.name } do
      patch event_url(@event), params: { event: { name: "Renamed" } }
    end

    assert_no_difference "Event.count" do
      delete event_url(@event)
    end

    assert_no_difference "EventTransaction.count" do
      post exclude_transaction_event_url(@event), params: { transaction_id: spend.id }
    end
  end

  # Index ----------------------------------------------------------------

  test "index lists this family's events and no other family's" do
    get events_url

    assert_response :success
    assert_select "a[href=?]", event_path(@event), text: /Bali trip/
    assert_select "a[href=?]", event_path(@other_event), count: 0
    assert_no_match(/Other family trip/, response.body)
  end

  test "index shows an empty state when the family has no events" do
    Event.where(family: @user.family).delete_all

    get events_url

    assert_response :success
    assert_select "a[href=?]", new_event_path
  end

  # Show -----------------------------------------------------------------

  test "show reports the true cost net of a refund" do
    txn(0, amount: 100, name: "Villa")
    txn(2, amount: -30, name: "Refund")

    get event_url(@event)

    assert_response :success
    assert_match(/\$70\.00/, response.body)
    assert_no_match(/\$130\.00/, response.body)
  end

  test "show lists the event's transactions and not those outside the range" do
    txn(1, name: "Inside spend")
    txn(40, name: "Outside spend")

    get event_url(@event)

    assert_match(/Inside spend/, response.body)
    assert_no_match(/Outside spend/, response.body)
  end

  test "show draws the day-by-day chart and the category donut from the event's figures" do
    food = @user.family.categories.create!(name: "Trip food")
    txn(0, amount: 40, category: food)
    txn(3, amount: 25, category: food)

    get event_url(@event)

    assert_select "[data-controller='time-series-chart']"
    assert_select "[data-controller='donut-chart']"
    chart = JSON.parse(css_select("[data-controller='time-series-chart']").first["data-time-series-chart-data-value"])
    assert_equal 5, chart["values"].size
    assert_equal 65.0, chart["values"].last["value"]["amount"].to_f
  end

  test "show offers nearby transactions to add and removed ones to restore" do
    nearby = txn(6, name: "Airport taxi home")
    removed = txn(1, name: "Not part of the trip")
    @event.exclude_transaction!(removed)

    get event_url(@event)

    assert_response :success
    assert_select "form[action=?]", include_transaction_event_path(@event)
    assert_select "option[value=?]", nearby.id
    assert_select "form[action=?]", reset_transaction_event_path(@event) do
      assert_select "input[name=transaction_id][value=?]", removed.id
    end
  end

  test "show marks a transaction added by hand and offers the right button for each row" do
    dated = txn(1, name: "Dated spend")
    manual = txn(9, name: "Early deposit")
    @event.include_transaction!(manual)

    get event_url(@event)

    assert_response :success
    assert_match(/Early deposit/, response.body)
    assert_match(/Added by hand/, response.body)
    assert_select "form[action=?]", exclude_transaction_event_path(@event) do
      assert_select "input[name=transaction_id][value=?]", dated.id
    end
    assert_select "form[action=?]", reset_transaction_event_path(@event) do
      assert_select "input[name=transaction_id][value=?]", manual.id
    end
    assert_select "input[name=transaction_id][value=?]", manual.id, count: 1
  end

  test "show renders for an event with no transactions" do
    get event_url(@event)

    assert_response :success
  end

  test "show does not reveal transactions on accounts the viewer cannot see" do
    private_account = Account.create!(family: @user.family, owner: users(:family_member), name: "Member private", currency: "USD", balance: 0, accountable: Depository.new)
    create_transaction(account: private_account, date: @day0 + 1, amount: 321, name: "Members secret spend")
    create_transaction(account: private_account, date: @day0 + 6, amount: 77, name: "Members nearby spend")

    get event_url(@event)

    assert_response :success
    assert_no_match(/Members secret spend/, response.body)
    assert_no_match(/Members nearby spend/, response.body)
    assert_no_match(/\$321\.00/, response.body)
  end

  test "show does not list a hidden account's transaction among those removed by hand" do
    private_account = Account.create!(family: @user.family, owner: users(:family_member), name: "Member private", currency: "USD", balance: 0, accountable: Depository.new)
    hidden = create_transaction(account: private_account, date: @day0 + 1, amount: 321, name: "Members removed spend").entryable
    visible = txn(2, name: "Own removed spend")
    @event.exclude_transaction!(hidden)
    @event.exclude_transaction!(visible)

    get event_url(@event)

    assert_response :success
    assert_match(/Own removed spend/, response.body)
    assert_no_match(/Members removed spend/, response.body)
  end

  # Family scoping -------------------------------------------------------

  test "another family's event is a 404 on every member route" do
    spend = txn(1)

    get event_url(@other_event)
    assert_response :not_found

    get edit_event_url(@other_event)
    assert_response :not_found

    assert_no_changes -> { @other_event.reload.name } do
      patch event_url(@other_event), params: { event: { name: "Hijacked" } }
    end
    assert_response :not_found

    assert_no_difference "Event.count" do
      delete event_url(@other_event)
    end
    assert_response :not_found

    assert_no_difference "EventTransaction.count" do
      post include_transaction_event_url(@other_event), params: { transaction_id: spend.id }
      assert_response :not_found
      post exclude_transaction_event_url(@other_event), params: { transaction_id: spend.id }
      assert_response :not_found
    end
  end

  # Create / update / destroy -------------------------------------------

  test "new renders the form" do
    get new_event_url

    assert_response :success
    assert_select "form[action=?]", events_path
  end

  test "create makes an event in the current family" do
    assert_difference -> { @user.family.events.count }, 1 do
      post events_url, params: { event: { name: "Japan", start_date: "2020-06-01", end_date: "2020-06-10", color: "#6471eb" } }
    end

    event = @user.family.events.find_by!(name: "Japan")
    assert_redirected_to event_path(event)
    assert_equal Date.new(2020, 6, 10), event.end_date
  end

  test "create ignores a family id in the params" do
    other_family = @other_event.family

    assert_no_difference -> { other_family.events.count } do
      post events_url, params: { event: { name: "Smuggled", start_date: "2020-06-01", end_date: "2020-06-10", family_id: other_family.id } }
    end

    assert_equal @user.family, Event.find_by!(name: "Smuggled").family
  end

  test "create with an end before the start is refused" do
    assert_no_difference "Event.count" do
      post events_url, params: { event: { name: "Backwards", start_date: "2020-06-10", end_date: "2020-06-01" } }
    end

    assert_response :unprocessable_entity
    assert_match(/on or after the start date/, response.body)
  end

  test "create with a bad colour is refused" do
    assert_no_difference "Event.count" do
      post events_url, params: { event: { name: "Colourless", start_date: "2020-06-01", end_date: "2020-06-02", color: "red" } }
    end

    assert_response :unprocessable_entity
  end

  test "edit renders the form" do
    get edit_event_url(@event)

    assert_response :success
    assert_select "form[action=?]", event_path(@event)
  end

  test "update changes the event and the dates move its transactions" do
    inside = txn(4, name: "Last day spend")

    patch event_url(@event), params: { event: { name: "Bali, shorter", end_date: (@day0 + 2).to_s } }

    assert_redirected_to event_path(@event)
    assert_equal "Bali, shorter", @event.reload.name
    assert_not_includes @event.transactions.pluck(:id), inside.id
  end

  test "update cannot move an event to another family" do
    patch event_url(@event), params: { event: { family_id: @other_event.family_id } }

    assert_equal @user.family, @event.reload.family
  end

  test "update with an end before the start is refused and changes nothing" do
    assert_no_changes -> { @event.reload.attributes } do
      patch event_url(@event), params: { event: { end_date: (@day0 - 1).to_s } }
    end

    assert_response :unprocessable_entity
  end

  test "destroy removes the event and its overrides but not the transactions" do
    spend = txn(8)
    @event.include_transaction!(spend)

    assert_difference [ "Event.count", "EventTransaction.count" ], -1 do
      assert_no_difference "Transaction.count" do
        delete event_url(@event)
      end
    end

    assert_redirected_to events_path
  end

  # The page needs the totals for the cost card and the category breakdown; it reads
  # them once, not once per figure.
  test "show runs the event's totals query once" do
    txn(1)
    IncomeStatement::Totals.expects(:new).once.returns(stub(call: []))

    get event_url(@event)

    assert_response :success
  end

  # Overrides ------------------------------------------------------------

  test "include pulls in a transaction dated outside the range" do
    outside = txn(8)
    before = @event.transactions.pluck(:id)

    post include_transaction_event_url(@event), params: { transaction_id: outside.id }

    assert_redirected_to event_path(@event)
    assert_equal [ outside.id ], @event.transactions.pluck(:id) - before
  end

  test "exclude removes a transaction dated inside the range" do
    inside = txn(2)
    before = @event.transactions.pluck(:id)

    post exclude_transaction_event_url(@event), params: { transaction_id: inside.id }

    assert_redirected_to event_path(@event)
    assert_equal [ inside.id ], before - @event.transactions.pluck(:id)
  end

  test "include and exclude refuse a transaction that cannot count towards an event, and write nothing" do
    savings = accounts(:depository).family.accounts.create!(name: "Savings", currency: "USD", balance: 0, accountable: Depository.new)
    create_transfer(from_account: @account, to_account: savings, amount: 500, date: @day0 + 9)
    transfer_leg = @account.transactions.find_by!(kind: "funds_movement")

    assert_no_difference "EventTransaction.count" do
      post include_transaction_event_url(@event), params: { transaction_id: transfer_leg.id }
      assert_redirected_to event_path(@event)
      assert_equal I18n.t("events.include_transaction.not_countable"), flash[:alert]

      post exclude_transaction_event_url(@event), params: { transaction_id: transfer_leg.id }
      assert_redirected_to event_path(@event)
      assert_equal I18n.t("events.exclude_transaction.not_countable"), flash[:alert]
    end
  end

  test "reset still removes an override on a transaction that has since stopped counting" do
    inside = txn(2)
    @event.exclude_transaction!(inside)
    inside.entry.update!(excluded: true)

    assert_difference "@event.event_transactions.count", -1 do
      delete reset_transaction_event_url(@event), params: { transaction_id: inside.id }
    end
  end

  test "reset drops the override" do
    inside = txn(2)
    @event.exclude_transaction!(inside)

    assert_difference "@event.event_transactions.count", -1 do
      delete reset_transaction_event_url(@event), params: { transaction_id: inside.id }
    end

    assert_redirected_to event_path(@event)
    assert_includes @event.transactions.pluck(:id), inside.id
  end

  test "another family's transaction cannot be attached" do
    foreign_account = @other_event.family.accounts.create!(name: "Foreign", currency: "USD", balance: 0, accountable: Depository.new)
    foreign = create_transaction(account: foreign_account, date: @day0 + 1).entryable

    assert_no_difference "EventTransaction.count" do
      post include_transaction_event_url(@event), params: { transaction_id: foreign.id }
    end
    assert_response :not_found
  end

  test "a transaction on an account the viewer cannot see cannot be attached" do
    private_account = Account.create!(family: @user.family, owner: users(:family_member), name: "Member private", currency: "USD", balance: 0, accountable: Depository.new)
    hidden = create_transaction(account: private_account, date: @day0 + 20).entryable

    assert_no_difference "EventTransaction.count" do
      post include_transaction_event_url(@event), params: { transaction_id: hidden.id }
    end
    assert_response :not_found
  end

  test "an unknown transaction id is a 404" do
    assert_no_difference "EventTransaction.count" do
      post include_transaction_event_url(@event), params: { transaction_id: SecureRandom.uuid }
    end
    assert_response :not_found
  end

  private
    def disable_preview
      @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => false))
    end

    # An expense on the given day (an offset from the event's first day) in the
    # family's own account; returns the Transaction.
    def txn(offset, amount: 10, name: "Spend", category: nil)
      create_transaction(account: @account, date: @day0 + offset, amount: amount, name: name, category: category).entryable
    end
end
