class SpendingNarrativesController < ApplicationController
  before_action :require_preview_features!

  def show
    # One date for the whole page: the period, the pace's elapsed fraction and
    # the previous window all derive from it, so they cannot straddle midnight.
    #
    # `owner=household` is the link a household pace insight carries: the page
    # then shows the budget the card was computed against, not the viewer's own.
    @narrative = Spending::Narrative.new(family: Current.family, user: Current.user, on: Date.current, household: params[:owner] == "household")
    @pace = @narrative.pace
    @movers = @narrative.top_movers
    @heatmap = @narrative.heatmap
    @breadcrumbs = [ [ t("breadcrumbs.home"), root_path ], [ t("spending_narratives.show.title"), nil ] ]
  end
end
