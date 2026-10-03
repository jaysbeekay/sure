class EventsController < ApplicationController
  before_action :require_preview_features!
  before_action :set_event, only: %i[show edit update destroy include_transaction exclude_transaction reset_transaction]
  before_action :set_transaction, only: %i[include_transaction exclude_transaction reset_transaction]

  # Longest transaction list the show page renders; the rest are one click away
  # on the transactions page, filtered to the event's dates.
  TRANSACTION_LIST_LIMIT = 200
  NEARBY_WINDOW_DAYS = 14
  NEARBY_LIMIT = 100

  def index
    @events = Current.family.events.chronological
    @breadcrumbs = reports_breadcrumbs + [ [ t("events.index.title"), nil ] ]
  end

  def show
    user = Current.user
    rows = @event.totals_rows(user: user)
    @true_cost = @event.true_cost(user: user, rows: rows)
    @category_breakdown = @event.category_breakdown(user: user, rows: rows)
    @cumulative_series = @event.cumulative_series(user: user)

    transactions = @event.transactions(user: user)
    @transaction_count = transactions.count
    @transactions = transactions.includes(:category, entry: :account).reverse_chronological.limit(TRANSACTION_LIST_LIMIT).to_a
    @manually_included_ids = @event.event_transactions.included.pluck(:transaction_id).to_set
    @removed = removed_transactions(user)
    @nearby_window = NEARBY_WINDOW_DAYS
    @nearby = @event.nearby_transactions(user: user, within: NEARBY_WINDOW_DAYS)
      .includes(entry: :account).reverse_chronological.limit(NEARBY_LIMIT).to_a

    @breadcrumbs = reports_breadcrumbs + [ [ t("events.index.title"), events_path ], [ @event.name, nil ] ]
  end

  def new
    @event = Current.family.events.new(color: Event::COLORS.sample)
    @breadcrumbs = reports_breadcrumbs + [ [ t("events.index.title"), events_path ], [ t("events.new.title"), nil ] ]
  end

  def create
    @event = Current.family.events.build(event_params)

    if @event.save
      redirect_to event_path(@event), notice: t(".created")
    else
      @breadcrumbs = reports_breadcrumbs + [ [ t("events.index.title"), events_path ], [ t("events.new.title"), nil ] ]
      render :new, status: :unprocessable_entity
    end
  end

  def edit
    @breadcrumbs = reports_breadcrumbs + [ [ t("events.index.title"), events_path ], [ @event.name, event_path(@event) ], [ t("events.edit.title"), nil ] ]
  end

  def update
    if @event.update(event_params)
      redirect_to event_path(@event), notice: t(".updated")
    else
      @breadcrumbs = reports_breadcrumbs + [ [ t("events.index.title"), events_path ], [ @event.name_was, event_path(@event) ], [ t("events.edit.title"), nil ] ]
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @event.destroy!
    redirect_to events_path, notice: t(".destroyed")
  end

  def include_transaction
    return redirect_to(event_path(@event), alert: t(".not_countable")) unless @event.countable?(@transaction, user: Current.user)

    @event.include_transaction!(@transaction)
    redirect_to event_path(@event), notice: t(".included")
  end

  def exclude_transaction
    return redirect_to(event_path(@event), alert: t(".not_countable")) unless @event.countable?(@transaction, user: Current.user)

    @event.exclude_transaction!(@transaction)
    redirect_to event_path(@event), notice: t(".excluded")
  end

  def reset_transaction
    @event.reset_transaction!(@transaction)
    redirect_to event_path(@event), notice: t(".reset")
  end

  private
    def set_event
      @event = Current.family.events.find_by!(id: params[:id])
    end

    # Only a transaction the viewer can see in their own finances may be
    # attached, so an id for someone else's private account is a 404, not a
    # way to probe it.
    def set_transaction
      @transaction = Current.family.transactions
        .where(entries: { account_id: Current.user.finance_accounts.select(:id) })
        .find_by!(id: params[:transaction_id])
    end

    def removed_transactions(user)
      ids = @event.event_transactions.excluded.pluck(:transaction_id)
      return [] if ids.empty?

      Current.family.transactions
        .where(id: ids, entries: { account_id: user.finance_accounts.select(:id) })
        .includes(entry: :account)
        .reverse_chronological
        .to_a
    end

    def reports_breadcrumbs
      [ [ t("breadcrumbs.home"), root_path ], [ t("breadcrumbs.reports"), reports_path ] ]
    end

    def event_params
      params.require(:event).permit(:name, :start_date, :end_date, :color)
    end
end
