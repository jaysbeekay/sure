class PortfoliosController < ApplicationController
  include Periodable

  before_action :require_preview_features!

  def show
    # `as_of` is captured once and passed down: every section reads the same
    # "today", so a render that straddles midnight can't mix two dates, and
    # the partials stay pure (no Date.current / Current.family lookups of
    # their own).
    @as_of = Date.current
    @statement = Current.family.investment_statement(user: Current.user)
    @sections = Portfolio::SectionRegistry.new(
      statement: @statement,
      period: @period,
      as_of: @as_of,
      user: Current.user
    ).sections

    @breadcrumbs = [ [ t("breadcrumbs.home"), root_path ], [ t("breadcrumbs.portfolio"), nil ] ]
  end

  def update_preferences
    if Current.user.update_section_preferences(
      "portfolio",
      order: preferences_params["portfolio_section_order"],
      collapsed: preferences_params["portfolio_collapsed_sections"]
    )
      head :ok
    else
      head :unprocessable_entity
    end
  end

  private
    # Allow-list, mirroring ReportsController#preferences_params: only the two
    # portfolio keys survive, so a payload naming another page's preference
    # (or an arbitrary user attribute) is dropped rather than written.
    def preferences_params
      @preferences_params ||= begin
        prefs = params.require(:preferences)

        {}.tap do |permitted|
          if prefs[:portfolio_collapsed_sections].present?
            collapsed = prefs[:portfolio_collapsed_sections].to_unsafe_h
            permitted["portfolio_collapsed_sections"] = collapsed.transform_values { |v| ActiveModel::Type::Boolean.new.cast(v) == true }
          end

          if prefs[:portfolio_section_order].present?
            permitted["portfolio_section_order"] = Array(prefs[:portfolio_section_order]).map(&:to_s)
          end
        end
      end
    end
end
