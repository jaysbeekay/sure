require "application_system_test_case"

# A bill's "..." menu opens against its button. The All bills list sits in a
# size container, and floating-ui 0.2.9 took any `container-type` ancestor for
# the containing block of a `position: fixed` menu, so it subtracted the
# container's offset and the menu opened a container's width away, mid-page.
class BillMenuPositionTest < ApplicationSystemTestCase
  setup do
    sign_in @user = users(:family_admin)
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => true))

    due = Date.current + 10
    @user.family.recurring_transactions.create!(
      name: "City Water", account: accounts(:depository), amount: 80, currency: "USD",
      expected_day_of_month: due.day, last_occurrence_date: due - 1.month,
      next_expected_date: due, status: "active"
    )
  end

  test "on a desktop, the All bills menu opens under its button, right edges aligned" do
    button, menu = open_first_menu

    # Not near the button: on it. The defect put the right edge 445px left of
    # the button's, so a loose tolerance would still prove the fix.
    assert_in_delta button["right"], menu["right"], 1, "menu is not aligned to its button"
    assert_operator menu["top"], :>=, button["bottom"], "menu does not open below its button"
    assert_operator menu["top"] - button["bottom"], :<=, 20, "menu opens far below its button"
  end

  test "on a phone, the All bills menu spans the screen directly under its button" do
    page.driver.browser.manage.window.resize_to(375, 812)
    button, menu = open_first_menu

    # The full-width branch sets left and width itself, so only the top comes
    # from floating-ui, and the defect moved the top too.
    assert_equal 0, menu["left"]
    assert_operator menu["top"], :>=, button["bottom"], "menu does not open below its button"
    assert_operator menu["top"] - button["bottom"], :<=, 20, "menu opens far below its button"
  ensure
    reset_viewport
  end

  private
    def open_first_menu
      visit bills_url(view: "all")
      # A row's menu, not the page header's, which sits outside the container.
      button = find(%q(.\@container [data-DS--menu-target="button"]), match: :first)
      button.click
      menu = find("##{button["aria-controls"]}", visible: true)

      rect = ->(node) { node.evaluate_script("(r => ({ left: r.left, top: r.top, right: r.right, bottom: r.bottom }))(this.getBoundingClientRect())") }
      [ rect.(button), rect.(menu) ]
    end
end
