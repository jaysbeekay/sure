require "test_helper"

# `var(--token)` is NOT substituted in an SVG *presentation attribute*. Only in
# a CSS declaration. An unresolvable presentation attribute leaves the property
# at its initial value -- `stroke: none` -- so the element is in the DOM with
# correct geometry and paints nothing. No error, no warning, no failing test:
# just an invisible line.
#
# This makes a new occurrence a build failure rather than a review catch, and
# rather than a bug report from someone who noticed a line was missing.
#
# The fix is always the same: resolve the token to a concrete value first
#
#   getComputedStyle(document.documentElement).getPropertyValue("--color-x")
#
# or set it through `.style()`, where var() does resolve.
class SvgTokenResolutionTest < ActiveSupport::TestCase
  CONTROLLERS = Rails.root.glob("app/javascript/controllers/*.js").freeze

  # Pre-existing occurrences, recorded rather than fixed here.
  #
  # Each is a genuine suspect, but confirming them needs a browser and each fix
  # touches a chart this change has no business touching. They are listed so
  # that the guard can be switched on now and the list can only shrink --
  # deleting an entry is the fix, adding one requires arguing for it.
  #
  # `time_series_chart_controller.js` is the one to look at first: it drives
  # shared/_sparkline, which renders on every account row.
  KNOWN_OCCURRENCES = {
    "goal_projection_chart_controller.js" => 1,
    "sankey_chart_controller.js" => 1,
    "spending_chart_controller.js" => 1,
    "time_series_chart_controller.js" => 3
  }.freeze

  # `.attr("stroke", ... var(--x) ...)` on one line, which is how every known
  # occurrence is written -- including sankey's ternary, which is why this
  # cannot stop at the first closing paren. A call split across lines would slip
  # past; the guard is a ratchet, not a proof.
  PATTERN = /\.attr\(\s*["'](?:stroke|fill|stop-color|color)["'][^\n]*var\(--/

  test "no new design token is passed to an SVG presentation attribute" do
    found = CONTROLLERS.each_with_object({}) do |path, acc|
      count = File.read(path).scan(PATTERN).length
      acc[path.basename.to_s] = count if count.positive?
    end

    unexpected = found.reject { |name, count| KNOWN_OCCURRENCES[name] == count }
    fixed = KNOWN_OCCURRENCES.reject { |name, _| found.key?(name) }

    assert_empty unexpected,
      "var() in an SVG presentation attribute renders nothing. Resolve the token first, " \
      "or use .style(). Unexpected: #{unexpected.inspect}"

    assert_empty fixed,
      "#{fixed.keys.join(', ')} no longer matches -- remove it from KNOWN_OCCURRENCES so the " \
      "list keeps shrinking"
  end
end
