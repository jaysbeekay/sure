require "test_helper"

class InsightsHelperTest < ActionView::TestCase
  test "positive types render success regardless of priority" do
    insight = build_insight("net_worth_milestone", priority: "high", metadata: { "milestone" => 500_000 })

    assert_equal :positive, insight_sentiment(insight)
    assert_equal "success", insight_icon_color(insight)
  end

  test "savings rate improvement is positive even at high priority" do
    insight = build_insight(
      "savings_rate_change",
      priority: "high",
      metadata: { "current_rate" => 32.5, "previous_rate" => 20.1 }
    )

    assert_equal :positive, insight_sentiment(insight)
    assert_equal "success", insight_icon_color(insight)
  end

  test "savings rate drop warns without going red" do
    insight = build_insight(
      "savings_rate_change",
      priority: "high",
      metadata: { "current_rate" => -5.4, "previous_rate" => 45.2 }
    )

    assert_equal :warning, insight_sentiment(insight)
    assert_equal "warning", insight_icon_color(insight)
  end

  test "spending anomaly direction decides sentiment" do
    above = build_insight("spending_anomaly", metadata: { "direction" => "above" })
    below = build_insight("spending_anomaly", metadata: { "direction" => "below" })

    assert_equal :warning, insight_sentiment(above)
    assert_equal :positive, insight_sentiment(below)
  end

  test "only a projected-negative balance renders destructive" do
    negative = build_insight("cash_flow_warning", priority: "high", metadata: { "negative" => true })
    low = build_insight("cash_flow_warning", priority: "medium", metadata: { "negative" => false })

    assert_equal "destructive", insight_icon_color(negative)
    assert_equal "warning", insight_icon_color(low)
  end

  test "informational types stay neutral" do
    %w[subscription_audit idle_cash].each do |type|
      assert_equal :neutral, insight_sentiment(build_insight(type))
      assert_equal "default", insight_icon_color(build_insight(type))
    end
  end

  test "rows written before the metadata shape change degrade safely" do
    stale = build_insight("cash_flow_warning", priority: "high", metadata: { "projected_low_amount" => 320.0 })

    assert_equal :warning, insight_sentiment(stale)
  end

  test "meta line shows the type and a month-aligned period as the month name" do
    insight = build_insight(
      "savings_rate_change",
      period_start: Date.new(Date.current.year, 6, 1),
      period_end: Date.new(Date.current.year, 6, 30)
    )

    assert_equal "Savings rate · June", insight_meta_line(insight)
  end

  test "meta line labels a forward-looking window as next N days" do
    travel_to Date.new(2026, 8, 1) do
      insight = build_insight(
        "cash_flow_warning",
        period_start: Date.current,
        period_end: Date.current + 30
      )

      assert_equal "Cash flow · Next 30 days", insight_meta_line(insight)
    end
  end

  test "meta line labels a backward-looking rolling window as last N days" do
    travel_to Date.new(2026, 8, 31) do
      insight = build_insight(
        "net_worth_milestone",
        period_start: Date.current - 30,
        period_end: Date.current
      )

      assert_equal "Net worth · Last 30 days", insight_meta_line(insight)
    end
  end

  test "meta line keeps monthly insight periods labeled as the month on boundaries" do
    travel_to Date.new(2026, 8, 1) do
      insight = build_insight(
        "budget_at_risk",
        period_start: Date.current.beginning_of_month,
        period_end: Date.current.end_of_month
      )

      assert_equal "Budget · August", insight_meta_line(insight)
    end
  end

  test "meta line falls back to the subject when there is no period" do
    insight = build_insight("idle_cash", facts: { "account" => "Emergency fund" })

    assert_equal "Idle cash · Emergency fund", insight_meta_line(insight)
  end

  test "key figure comes from facts and hides for rows without them" do
    with_facts = build_insight("idle_cash", facts: { "balance" => "$28,400.00", "idle_days" => 60 })
    without_facts = build_insight("idle_cash")

    assert_equal "$28,400.00", insight_key_figure(with_facts).first
    assert_nil insight_key_figure(without_facts)
  end

  # The two budget cards share `budget_spent_pct` in facts but not a subject:
  # at-risk is about how many categories are in trouble, on-track is about
  # overall consumption. Showing consumption on the at-risk card put a
  # reassuring figure next to a warning headline.
  test "budget at risk leads with the flagged count, not overall consumption" do
    insight = build_insight("budget_at_risk", facts: { "count" => 2, "budget_spent_pct" => 14 })

    figure, caption = insight_key_figure(insight)

    assert_equal "2", figure
    assert_equal "need attention", caption
  end

  test "budget on track still leads with overall consumption" do
    insight = build_insight("budget_on_track", facts: { "budget_spent_pct" => 62 })

    figure, caption = insight_key_figure(insight)

    assert_equal "62%", figure
    assert_equal "of budget", caption
  end

  test "privacy text wraps amounts, percentages and counts in privacy-sensitive spans" do
    body = "Your grocery spending is at €288.59, which is 142% above your usual €119.01."

    rendered = insight_privacy_text(body)

    assert_predicate rendered, :html_safe?
    assert_equal <<~HTML.strip, rendered
      Your grocery spending is at <span class="privacy-sensitive">€288.59</span>, which is <span class="privacy-sensitive">142%</span> above your usual <span class="privacy-sensitive">€119.01</span>.
    HTML
  end

  test "privacy text handles locale formats with suffix currency and no-break-space grouping" do
    rendered = insight_privacy_text("Checking holds 1 234,56 € with no activity in the last 45 days.")

    assert_includes rendered, %(<span class="privacy-sensitive">1 234,56 €</span>)
    assert_includes rendered, %(<span class="privacy-sensitive">45</span> days)
  end

  test "privacy text leaves numberless prose untouched and escapes HTML" do
    assert_equal "Is Netflix still active?", insight_privacy_text("Is Netflix still active?")
    assert_equal "", insight_privacy_text(nil)

    rendered = insight_privacy_text("It's <b>big</b>: $1,200.50")

    assert_includes rendered, "It&#39;s &lt;b&gt;big&lt;/b&gt;:"
    assert_includes rendered, %(<span class="privacy-sensitive">$1,200.50</span>)
  end

  test "action link resolves the stored subject and disappears when it cannot" do
    account = families(:dylan_family).accounts.visible.first
    resolvable = build_insight("idle_cash", metadata: { "account_id" => account.id })
    dangling = build_insight("idle_cash", metadata: { "account_id" => SecureRandom.uuid })

    assert_equal account_path(account), insight_action(resolvable)[:href]
    assert_nil insight_action(dangling)
  end

  test "stale valuation action opens the valuation form for that account in the modal" do
    account = accounts(:property)
    insight = build_insight("stale_valuation", metadata: { "account_id" => account.id })
    Current.stubs(:user).returns(users(:family_admin))

    action = insight_action(insight)

    assert_equal new_valuation_path(account_id: account.id), action[:href]
    assert_equal :modal, action[:frame]
    assert_equal "Update value", action[:text]
  end

  test "stale valuation action disappears when the account does not resolve" do
    insight = build_insight("stale_valuation", metadata: { "account_id" => SecureRandom.uuid })

    assert_nil insight_action(insight)
  end

  test "only the stale valuation action targets the modal frame" do
    account = accounts(:property)
    other = build_insight("idle_cash", metadata: { "account_id" => account.id })

    assert_nil insight_action(other)[:frame]
  end

  test "stale valuation key figure is the balance with the days unvalued" do
    insight = build_insight("stale_valuation", facts: { "balance" => "$550,000.00" },
                            metadata: { "last_valued_on" => 91.days.ago.to_date.iso8601 })

    assert_equal [ "$550,000.00", "unvalued 91 days" ], insight_key_figure(insight)
    assert_equal "calendar-clock", insight_icon_key(insight)
    assert_equal :warning, insight_sentiment(insight)
  end

  # The days are worked out when the card renders, so they keep up with the
  # calendar between the nightly runs that would otherwise refresh them.
  test "stale valuation days advance without the insight being regenerated" do
    insight = build_insight("stale_valuation", facts: { "balance" => "$550,000.00" },
                            metadata: { "last_valued_on" => 91.days.ago.to_date.iso8601 })

    travel 10.days do
      assert_equal "unvalued 101 days", insight_key_figure(insight).last
    end
  end

  test "stale valuation shows no key figure without a last valued date" do
    assert_nil insight_key_figure(build_insight("stale_valuation", facts: { "balance" => "$1.00" }))
  end

  test "stale valuation action is withheld from a user who cannot write the account" do
    account = accounts(:property)
    insight = build_insight("stale_valuation", metadata: { "account_id" => account.id })
    member = users(:family_member)

    Current.stubs(:user).returns(member)
    assert_nil insight_action(insight), "a user with no access"

    account.share_with!(member, permission: "read_only")
    assert_nil insight_action(insight), "read only"

    account.unshare_with!(member)
    account.share_with!(member, permission: "full_control")
    assert_equal new_valuation_path(account_id: account.id), insight_action(insight)[:href]

    Current.stubs(:user).returns(users(:family_admin))
    assert_equal new_valuation_path(account_id: account.id), insight_action(insight)[:href], "the owner"
  end

  # A broadcast render is one render for the whole family, so it cannot tell a
  # writer from a read-only member. It must not offer the link to either: the
  # difference from the writer case above is the only thing this test measures.
  test "stale valuation action is withheld where there is no current user, as in a broadcast" do
    account = accounts(:property)
    insight = build_insight("stale_valuation", metadata: { "account_id" => account.id })

    Current.stubs(:user).returns(users(:family_admin))
    assert insight_action(insight), "precondition: a writer is offered the action"

    Current.stubs(:user).returns(nil)
    assert_nil insight_action(insight)
  end

  test "maintained reserve metadata and action render in German" do
    family = families(:dylan_family)
    goal = family.goals.first
    insight = build_insight("maintained_goal_depleted", metadata: { "goal_id" => goal.id })

    I18n.with_locale(:de) do
      assert_equal "Rücklage", insight_meta_line(insight)
      assert_equal "Rücklage ansehen", insight_action(insight)[:text]
    end

    %w[types actions titles templates].each do |scope|
      assert I18n.exists?("insights.#{scope}.maintained_goal_depleted", :de, fallback: false)
    end
  end

  private
    def build_insight(insight_type, priority: "medium", metadata: {}, facts: {}, period_start: nil, period_end: nil)
      Insight.new(
        family: families(:dylan_family),
        insight_type: insight_type,
        priority: priority,
        status: "active",
        title: "t",
        body: "b",
        metadata: metadata,
        facts: facts,
        period_start: period_start,
        period_end: period_end,
        dedup_key: "#{insight_type}:test"
      )
    end
end
