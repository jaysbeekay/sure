# Preview: review AI category suggestions for the uncategorised backlog.
#
# Nothing is stored between requests. `create` runs one bounded batch and
# renders the suggestions into a form; `accept` receives them back and applies
# the ones posted. See Family::CategorySuggestionReview for the rules.
class Transactions::CategorySuggestionsController < ApplicationController
  before_action :require_preview_features!
  before_action :set_review
  before_action :set_breadcrumbs

  def index
    load_overview
  end

  def create
    load_overview

    unless @provider_configured
      render :index, status: :unprocessable_entity
      return
    end

    @batch = @review.suggest
    render :index
  rescue Family::AutoCategorizer::Error
    @failed = true
    render :index, status: :unprocessable_entity
  end

  def accept
    result = @review.accept(posted_rows)

    flash[:notice] = t(".applied", count: result.applied) if result.applied.positive?
    flash[:alert] = t(".skipped", count: result.skipped) if result.skipped.positive?
    flash[:alert] = t(".none_selected") if result.applied.zero? && result.skipped.zero?

    redirect_to transactions_category_suggestions_path
  end

  private
    def set_review
      @review = Family::CategorySuggestionReview.new(Current.family, user: Current.user)
    end

    def set_breadcrumbs
      @breadcrumbs = [
        [ t("breadcrumbs.home"), root_path ],
        [ t("breadcrumbs.transactions"), transactions_path ],
        [ t("breadcrumbs.category_suggestions"), nil ]
      ]
    end

    def load_overview
      @provider_configured = @review.provider_configured?
      @backlog_count = @review.backlog_count
      @batch_size = [ @backlog_count, Family::AutoCategorizer::SUGGEST_LIMIT ].min

      if @provider_configured && @batch_size.positive?
        @selected_model, @estimated_cost = Current.family.auto_categorize_estimate(transaction_count: @batch_size)
      end
    end

    # The rows come back from the form exactly as `create` rendered them.
    # Anything that is not a hash of rows is treated as nothing posted.
    def posted_rows
      raw = params[:suggestions]
      return [] unless raw.respond_to?(:values)

      rows = raw.values.filter_map do |row|
        row.permit(:transaction_id, :category_id, :token).to_h if row.respond_to?(:permit)
      end

      # A per-row Accept button names its row; Accept all names none.
      only = params[:only].to_s
      only.present? ? rows.select { |row| row[:transaction_id] == only } : rows
    end
end
