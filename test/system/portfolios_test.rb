require "application_system_test_case"

class PortfoliosTest < ApplicationSystemTestCase
  setup do
    @user = users(:family_admin)
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => true))
    sign_in @user
  end

  # The collapse state is saved with the page's CSRF token and nothing is
  # saved without one, and the test environment renders none unless forgery
  # protection is on.
  test "collapsing a section saves it under the portfolio keys, not the Reports ones" do
    original = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
    visit portfolio_path
    record_saved_section_order

    find("section[data-section-key='accounts'] summary").click

    assert_selector "section[data-section-key='accounts'] details:not([open])"
    assert_selector "html[data-order-saved='200']"
    assert_equal true, @user.reload.preferences.dig("portfolio_collapsed_sections", "accounts")
    assert_nil @user.preferences["reports_collapsed_sections"]
  ensure
    ActionController::Base.allow_forgery_protection = original
  end

  # A pick re-renders the sections frame with the new period: the picker's own
  # label is inside the frame, so it changes only if the frame was replaced.
  test "picking a period re-renders the sections for that period" do
    @user.update!(default_period: "last_30_days")
    visit portfolio_path

    find("button[aria-label='#{I18n.t("UI.period_picker.aria_label", period: "30D")}']").click
    click_link "5Y"

    assert_selector "button[aria-label='#{I18n.t("UI.period_picker.aria_label", period: "5Y")}']"
    assert_selector "turbo-frame#portfolio_sections section[data-section-key='kpis']"
    assert_selector "turbo-frame#portfolio_sections section[data-section-key='value_chart']"
    assert_equal "last_5_years", @user.reload.default_period
  end

  # The index chart reuses the time-series chart controller as it is: the
  # levels are plain numbers, not Money, and the controller must still draw
  # them as a line.
  test "the index chart draws its levels as a line" do
    Portfolio::Performance.any_instance.stubs(:index_series).returns([
      [ 2.days.ago.to_date, BigDecimal("100") ],
      [ 1.day.ago.to_date, BigDecimal("104.5") ],
      [ Date.current, BigDecimal("102.25") ]
    ])

    visit portfolio_path

    assert_selector "#portfolioIndexChart svg path[d]"
  end
end
