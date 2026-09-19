class HoldingsController < ApplicationController
  include StreamExtensions

  before_action :set_holding, only: %i[show update destroy unlock_cost_basis remap_security reset_security sync_prices tags classification reset_classification]
  before_action :require_holding_write_permission!, only: %i[update destroy unlock_cost_basis remap_security reset_security sync_prices tags classification reset_classification]

  def index
    @account = accessible_accounts.find(params[:account_id])
    @current_holdings = @account.current_holdings.includes(:account)
    @trade_republic_categories = trade_republic_categories_for(@account)
  end

  def show
    @last_price_updated = @holding.security.prices.maximum(:updated_at)
    @family_tags = Current.family.tags.alphabetically
  end

  # The family-scoped half of classification. Unlike the classification columns,
  # which live on the shared security row, a tagging is reachable only through
  # the owning family's tags -- so this is where a household's own scheme goes.
  #
  # The write itself is `Security#set_tags_for`, which replaces only this
  # family's taggings; `security.tags = ...` here would delete other families'.
  def tags
    @holding.security.set_tags_for(Current.family, params.dig(:security, :tag_ids))
    flash[:notice] = t("securities.tags.saved")

    redirect_to account_path(@holding.account, tab: "holdings")
  end

  def update
    total_cost_basis = holding_params[:cost_basis].to_d

    if total_cost_basis >= 0 && @holding.qty.positive?
      # Convert total cost basis to per-share cost (the cost_basis field stores per-share)
      # Zero is valid for gifted/inherited shares
      per_share_cost = total_cost_basis / @holding.qty
      @holding.set_manual_cost_basis!(per_share_cost)
      flash[:notice] = t(".success")
    else
      flash[:alert] = t(".error")
    end

    # Redirect to account page holdings tab to refresh list and close drawer
    redirect_to account_path(@holding.account, tab: "holdings")
  end

  # The user's own answer about what an instrument is. `"manual"` outranks every
  # other writer in `Security::Provided`, and `classification_locked` stops
  # `Security#apply_classification_defaults` -- but until this action existed
  # nothing in the application could set either, so both rules were unreachable
  # and a security the providers will not classify (an ETF, or a country the
  # region config does not name) stayed in the "Unclassified" bucket for good.
  #
  # `securities` has no `family_id`, so this writes a row every family holding
  # the security shares. That is what the slice specifies and it is harmless on
  # a self-hosted instance; a managed one wants a family-scoped override table
  # instead, tracked on #122.
  def classification
    security = @holding.security
    security.assign_attributes(classification_params)
    security.classification_source = "manual"
    security.classification_locked = true

    if security.save
      flash[:notice] = t("securities.classification.saved")
    else
      # The vocabularies are also database check constraints, so an
      # out-of-vocabulary value that reached Postgres would be a 500 rather
      # than a refusal. The model validations are what keep it a refusal.
      flash[:alert] = security.errors.full_messages.to_sentence
    end

    redirect_to account_path(@holding.account, tab: "holdings")
  end

  # Clears the classification outright rather than only lifting the lock. The
  # provider path only fills a field it finds EMPTY -- a sector the user set is
  # never restated -- so leaving the old values in place would lift the lock and
  # still leave the user's answer standing for ever.
  def reset_classification
    @holding.security.update!(
      asset_class: nil, asset_sub_class: nil, sector: nil, region: nil,
      classification_source: nil, classification_locked: false
    )
    flash[:notice] = t("securities.classification.reset_done")

    redirect_to account_path(@holding.account, tab: "holdings")
  end

  def unlock_cost_basis
    @holding.unlock_cost_basis!
    flash[:notice] = t(".success")

    # Redirect to account page holdings tab to refresh list and close drawer
    redirect_to account_path(@holding.account, tab: "holdings")
  end

  def destroy
    if @holding.account.can_delete_holdings?
      @holding.destroy_holding_and_entries!
      flash[:notice] = t(".success")
    else
      flash[:alert] = t(".cannot_delete")
    end

    respond_to do |format|
      format.html { redirect_back_or_to account_path(@holding.account) }
      format.turbo_stream { render turbo_stream: turbo_stream.action(:redirect, account_path(@holding.account)) }
    end
  end

  def remap_security
    # Combobox returns "TICKER|EXCHANGE|PROVIDER" format
    parsed = Security.parse_combobox_id(params[:security_id])

    # Validate ticker is present (form has required: true, but can be bypassed)
    if parsed[:ticker].blank?
      flash[:alert] = t(".security_not_found")
      redirect_to account_path(@holding.account, tab: "holdings")
      return
    end

    # The user explicitly selected this security from provider search results,
    # so we use the combobox data directly — no need to re-resolve via provider APIs.
    new_security = Security.find_or_initialize_by(
      ticker: parsed[:ticker],
      exchange_operating_mic: parsed[:exchange_operating_mic]
    )

    # Honor the user's provider choice (validated by model inclusion check on save)
    new_security.price_provider = parsed[:price_provider] if parsed[:price_provider].present?

    # Bring it online — user explicitly selected it from provider search results,
    # so we know the provider can handle it.
    new_security.offline = false
    new_security.failed_fetch_count = 0
    new_security.failed_fetch_at = nil

    new_security.save!

    @holding.remap_security!(new_security)

    # Re-materialize holdings with the new security's prices.
    # Reload account to avoid stale associations from remap_security!.
    # The around_action :switch_timezone already sets the family timezone
    # for this request, so Date.current is correct here.
    account = Account.find(@holding.account_id)
    strategy = account.linked? ? :reverse : :forward
    Balance::Materializer.new(account, strategy: strategy, security_ids: [ new_security.id ]).materialize_balances

    flash[:notice] = t(".success")

    respond_to do |format|
      format.html { redirect_to account_path(@holding.account, tab: "holdings") }
      format.turbo_stream { render turbo_stream: turbo_stream.action(:redirect, account_path(@holding.account, tab: "holdings")) }
    end
  end

  def sync_prices
    security = @holding.security

    if security.offline?
      redirect_to account_path(@holding.account, tab: "holdings"),
                  alert: t("holdings.sync_prices.unavailable")
      return
    end

    prices_updated, @provider_error = security.import_provider_prices(
      start_date: 31.days.ago.to_date,
      end_date: Date.current,
      clear_cache: true
    )
    security.import_provider_details

    @last_price_updated = @holding.security.prices.maximum(:updated_at)

    if prices_updated == 0
      @provider_error = @provider_error.presence || t("holdings.sync_prices.provider_error")
      respond_to do |format|
        format.html { redirect_to account_path(@holding.account, tab: "holdings"), alert: @provider_error }
        format.turbo_stream
      end
      return
    end

    strategy = @holding.account.linked? ? :reverse : :forward
    Balance::Materializer.new(@holding.account, strategy: strategy, security_ids: [ @holding.security_id ]).materialize_balances
    @holding.reload
    @last_price_updated = @holding.security.prices.maximum(:updated_at)

    respond_to do |format|
      format.html { redirect_to account_path(@holding.account, tab: "holdings"), notice: t("holdings.sync_prices.success") }
      format.turbo_stream
    end
  end

  def reset_security
    @holding.reset_security_to_provider!
    flash[:notice] = t(".success")

    respond_to do |format|
      format.html { redirect_to account_path(@holding.account, tab: "holdings") }
      format.turbo_stream { render turbo_stream: turbo_stream.action(:redirect, account_path(@holding.account, tab: "holdings")) }
    end
  end

  private

    def trade_republic_categories_for(account)
      provider = account.account_providers.includes(:provider).map(&:provider).find do |candidate|
        candidate.is_a?(TradeRepublicAccount) && candidate.portfolio?
      end
      return if provider.blank?

      values = Array(provider.raw_positions_payload).group_by { |position| position["category"].presence || "brokerage" }
      TradeRepublicClientCategories::ALL.index_with do |category|
        positions = values.fetch(category, [])
        {
          count: positions.size,
          value: positions.sum do |position|
            quantity = position["quantity"].presence&.to_d || BigDecimal("0")
            price = position["price"].presence&.to_d || BigDecimal("0")
            quantity * price
          end
        }
      end
    end
    def set_holding
      @holding = Current.family.holdings
                   .joins(:account)
                   .merge(Account.accessible_by(Current.user))
                   .find(params[:id])
    end

    def require_holding_write_permission!
      require_account_permission!(@holding.account)
    end

    def holding_params
      params.require(:holding).permit(:cost_basis)
    end

    # Blank is stored as nil, not "". `Security::Provided`'s skip gate asks
    # `sector.blank?` -- which an empty string satisfies -- while a `WHERE
    # sector IS NULL` would not, so the two would disagree about whether the
    # security is classified. One shape in the column keeps them agreeing.
    def classification_params
      params.require(:security)
            .permit(:asset_class, :asset_sub_class, :sector, :region)
            .to_h
            .transform_values { |value| value.is_a?(String) ? value.strip.presence : value }
    end
end
