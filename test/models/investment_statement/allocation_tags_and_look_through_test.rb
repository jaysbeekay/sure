require "test_helper"

# The two halves of IP3 that could not land with their own slices, because both
# need 3.4's grouping registry.
#
# 3.5's allocation by tag: the four classification axes are the same ones
# everyone gets; a tag is the household's own scheme, and grouping by it is the
# only reason to have tagged anything.
#
# 3.7's look-through: 3.1 refuses to classify an ETF, so a fund portfolio charts
# as Unclassified. Expanding a fund into what it holds is what makes the sector
# and region charts say anything at all for an index investor.
class InvestmentStatement::AllocationTagsAndLookThroughTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @account = accounts(:investment)
    @statement = InvestmentStatement.new(@family)
    @aapl = securities(:aapl)
    @tag = tags(:one)
    # The fixture holding's value, so the untagged test can assert that THIS
    # holding reached the bucket rather than that the bucket merely exists.
    @holding_value = @account.holdings.where(security: @aapl).order(:date).last.amount
  end

  # ------------------------------------------------------- 3.5: by tag

  test "tag is offered as a grouping" do
    assert_includes InvestmentStatement::ALLOCATION_GROUPINGS, "tag"
  end

  test "holdings group under the family's tag" do
    @aapl.set_tags_for(@family, [ @tag.id ])

    segments = @statement.allocation_by("tag")

    tagged = segments.find { |s| s.id == @tag.id.to_s }
    assert tagged, "no segment for the tag the security carries"
    assert_equal @tag.name, tagged.name
    assert tagged.amount.positive?
  end

  # Tags are family-scoped by construction, and the allocation must honour that
  # or one family's scheme would label another's chart -- `securities` is shared.
  test "another family's tag does not appear in this family's allocation" do
    other_family = users(:josh).family
    other_tag = other_family.tags.create!(name: "Their scheme")
    @aapl.taggings.create!(tag: other_tag)

    segments = @statement.allocation_by("tag")

    assert_nil segments.find { |s| s.name == "Their scheme" },
               "another family's tag labelled this family's allocation"
  end

  # A tag is not a taxonomy: a security can carry several, and one that carries
  # none still has to be somewhere or the amounts stop reconciling with the
  # portfolio total.
  #
  # Asserted by VALUE against another grouping, not by the presence of an
  # unclassified segment. The fixture investment account carries a positive cash
  # balance which `allocation_by_tag` also routes into UNCLASSIFIED, so a
  # presence assertion held even when the untagged branch was deleted outright --
  # the daily sweep caught that, and it is the same vacuity two other tests in
  # this file were already rewritten for.
  test "an untagged holding is carried, not dropped" do
    @aapl.set_tags_for(@family, [])

    tagged_total = @statement.allocation_by("tag").sum { |s| s.amount.amount }
    sector_total = @statement.allocation_by("sector").sum { |s| s.amount.amount }

    assert_in_delta sector_total.to_f, tagged_total.to_f, 0.01,
                    "the untagged holding's value is missing from the tag grouping"

    unclassified = @statement.allocation_by("tag").find { |s| s.id == InvestmentStatement::UNCLASSIFIED }
    assert unclassified, "an untagged holding had nowhere to go"
    assert unclassified.amount.amount >= @holding_value,
           "the untagged holding's own value did not reach the unclassified bucket"
  end

  # A security can carry several tags, unlike a taxonomy column. Counting it once
  # per tag makes the segments overrun the portfolio, and this section draws a
  # donut -- so the value is split. Asserted against the invariant #194 enforces:
  # every grouping adds up to the portfolio value.
  test "a holding carrying two tags is split between them, not counted twice" do
    second = @family.tags.create!(name: "Second scheme")
    @aapl.set_tags_for(@family, [ @tag.id, second.id ])

    segments = @statement.allocation_by("tag")
    first_amount = segments.find { |s| s.id == @tag.id.to_s }.amount.amount
    second_amount = segments.find { |s| s.id == second.id.to_s }.amount.amount

    assert_equal first_amount, second_amount, "the split was not even"
    # Compared against another grouping rather than against `portfolio_value`:
    # the fixture family carries balances the grouping walk legitimately does not
    # reach, so the two are not the same number here. #194's own invariant test
    # builds its accounts for that reason. What must hold is that tag measures
    # the same portfolio the other groupings do.
    assert_in_delta @statement.allocation_by("sector").sum { |s| s.amount.amount }.to_f,
                    segments.sum { |s| s.amount.amount }.to_f, 0.01,
                    "a multi-tagged holding was counted under every tag, overrunning the portfolio"
  end

  # Cash is not tagged, and every other grouping carries it. Leaving it out would
  # drop it from this grouping alone and break the same invariant.
  test "account cash is carried into the tag grouping" do
    @aapl.set_tags_for(@family, [ @tag.id ])

    segments = @statement.allocation_by("tag")

    assert_in_delta @statement.allocation_by("sector").sum { |s| s.amount.amount }.to_f,
                    segments.sum { |s| s.amount.amount }.to_f, 0.01,
                    "the tag grouping does not measure the same portfolio as the others"
  end

  # Codacy's review of this PR called the split a rounding risk: `value / n` for
  # an n that does not divide the value leaves the parts summing to less than
  # the whole. The invariant tests above could not have seen it -- they compare
  # groupings with `assert_in_delta … 0.01`, which is exactly the slop a lost
  # fraction hides in. Three tags is the smallest case that divides badly, and
  # this asserts the parts reconcile EXACTLY rather than nearly.
  test "a three-way tag split sums back to the holding's value exactly" do
    second = @family.tags.create!(name: "Second scheme")
    third = @family.tags.create!(name: "Third scheme")
    @aapl.set_tags_for(@family, [ @tag.id, second.id, third.id ])

    segments = @statement.allocation_by("tag").index_by(&:id)
    parts = [ @tag, second, third ].map { |tag| segments.fetch(tag.id.to_s).amount.amount }

    assert_equal 3, parts.compact.size, "all three tags must carry a slice, or this proves nothing"
    assert_equal @holding_value, parts.sum,
                 "the three parts do not add back to the whole: #{parts.map(&:to_s).join(' + ')}"
  end

  # Also Codacy's, and the one part of its N+1 finding the tests above do not
  # cover: they grow the HOLDING count, and the concern was a rate lookup per
  # CURRENCY inside the loop. InvestmentStatement#exchange_rates is memoised and
  # batched, so the count must not move when the portfolio gains two more
  # currencies -- and this is the assertion that fails if a later change starts
  # converting per holding instead.
  test "adding foreign currencies does not add queries to the tag grouping" do
    @aapl.set_tags_for(@family, [ @tag.id ])
    hold_foreign_security(0, "EUR")
    # A FRESH family both times. Reusing one leaves `family.tags` loaded on the
    # association after the first call, so the second runs one query fewer and
    # the comparison measures the cache rather than the currencies. I wrote that
    # version first and watched it report 9 against 8.
    one_currency = count_queries { InvestmentStatement.new(Family.find(@family.id)).allocation_by("tag") }

    hold_foreign_security(1, "GBP")
    hold_foreign_security(2, "JPY")
    three_currencies = count_queries { InvestmentStatement.new(Family.find(@family.id)).allocation_by("tag") }

    assert_equal one_currency, three_currencies,
                 "one foreign currency cost #{one_currency} queries and three cost " \
                 "#{three_currencies}; the rates are being fetched per currency"
  end

  # --------------------------------------------- 3.7: look-through

  test "without look-through a fund reports its own sector" do
    fund = fund_with_constituents

    segments = @statement.allocation_by("sector", look_through: false)

    assert segments.any? { |s| s.id == "Fund wrapper" },
           "the fund's own sector is not reported when look-through is off"
    assert_nil segments.find { |s| s.id == "Technology" }
    assert fund.constituents.any?
  end

  # The point of the slice. The fund's amount is redistributed across the
  # sectors of what it actually holds.
  test "with look-through a fund reports the sectors of its holdings" do
    fund_with_constituents

    segments = @statement.allocation_by("sector", look_through: true)

    assert_nil segments.find { |s| s.id == "Fund wrapper" },
               "the wrapper's own sector survived the look-through"
    assert segments.any? { |s| s.id == "Technology" }
    assert segments.any? { |s| s.id == "Healthcare" }
  end

  # The amounts must still add up: looking through redistributes a position, it
  # does not create or destroy value. Asserted against the same grouping with
  # the toggle off, so a drift of any size fails.
  test "look-through redistributes without changing the total" do
    fund_with_constituents

    without = @statement.allocation_by("sector", look_through: false).sum { |s| s.amount }
    with = @statement.allocation_by("sector", look_through: true).sum { |s| s.amount }

    assert_in_delta without.to_f, with.to_f, 0.01,
                    "the look-through changed the portfolio's total value"
  end

  # A constituent we hold no Security row for cannot be classified, so it has to
  # land somewhere rather than be dropped -- otherwise the total silently shrinks
  # by the weight of every unknown constituent, which for a broad fund is most
  # of it.
  # Asserted by VALUE, not by the presence of an unclassified segment. Another
  # holding already produces one, so "is there an unclassified bucket" passed
  # even when the unresolvable constituent was being dropped outright -- the
  # mutation run caught that. The total is what actually breaks.
  test "a constituent with no security row is carried, not dropped" do
    fund = create_fund
    fund.constituents.create!(ticker: "UNKNOWNCO", name: "Unknown Co", weight: 100)

    without = @statement.allocation_by("sector", look_through: false).sum { |s| s.amount.amount }
    segments = @statement.allocation_by("sector", look_through: true)
    with = segments.sum { |s| s.amount.amount }

    assert_in_delta without.to_f, with.to_f, 0.01,
                    "the portfolio total shrank by the weight of the unresolvable constituent"

    unclassified = segments.find { |s| s.id == InvestmentStatement::UNCLASSIFIED }
    assert unclassified, "an unresolvable constituent had nowhere to go"
    assert unclassified.amount.amount >= 1000,
           "the fund's value did not land in the unclassified bucket"
  end

  # A security that is not a fund must be untouched by the toggle, or every
  # ordinary holding would be reshaped by a feature that does not apply to it.
  test "a security with no constituents is unaffected by the toggle" do
    @aapl.update!(sector: "Technology")

    without = @statement.allocation_by("sector", look_through: false)
    with = @statement.allocation_by("sector", look_through: true)

    assert_equal without.map { |s| [ s.id, s.amount ] }.sort,
                 with.map { |s| [ s.id, s.amount ] }.sort
  end

  # ------------------------------------------------- query counts

  # Both groupings lazy-loaded per holding: `holding.security.taggings` and
  # `security.look_through_weights`. Measured at 19 and 42 queries against 5 for
  # `sector` on 13 holdings. Asserted against the `sector` grouping rather than
  # an absolute number, so the guard survives an unrelated change in how
  # holdings are loaded and only fails if these two start scaling again.
  test "grouping by tag does not query per holding" do
    5.times { |i| hold_another_security(i) }
    @aapl.set_tags_for(@family, [ @tag.id ])

    baseline = count_queries { @statement.allocation_by("sector") }
    tagged = count_queries { InvestmentStatement.new(@family).allocation_by("tag") }

    assert tagged <= baseline + 2,
           "tag grouping ran #{tagged} queries against #{baseline} for sector; it is querying per holding"
  end

  test "look-through does not query per holding" do
    5.times { |i| hold_another_security(i) }
    fund_with_constituents

    baseline = count_queries { InvestmentStatement.new(@family).allocation_by("sector") }
    looked = count_queries { InvestmentStatement.new(@family).allocation_by("sector", look_through: true) }

    assert looked <= baseline + 2,
           "look-through ran #{looked} queries against #{baseline} without it; it is querying per holding"
  end

  # A constituent that is itself a cash security belongs in liquidity/cash, the
  # same as a directly held one. Passing nil as the cash bucket filed it under
  # UNCLASSIFIED, so the same money answered differently depending on how it was
  # held.
  test "a cash constituent lands in liquidity, as a directly held one would" do
    fund = create_fund
    cash = Security.create!(ticker: "CASHC", exchange_operating_mic: "XNAS", kind: "cash", offline: true)
    # Emptied deliberately. The defaults slice fills a cash security with
    # liquidity/cash on create, and with those columns set the bucket resolves
    # correctly whether or not `cash_bucket` is carried through -- so the test
    # would pass either way. A row predating that slice, or written by
    # `update_columns`, is the case the carry-through actually decides.
    cash.update_columns(asset_class: nil, asset_sub_class: nil, classification_source: nil)
    fund.constituents.create!(ticker: "CASHC", name: "Cash holding", weight: 100)

    # By VALUE, not by presence: the fixture account's own cash balance already
    # produces a `liquidity` segment, so "is there one" passed whether or not
    # the constituent reached it. Asserted as the DELTA the look-through adds.
    assert cash.cash?
    before = liquidity_amount(@statement.allocation_by("asset_class", look_through: false))
    after = liquidity_amount(InvestmentStatement.new(@family).allocation_by("asset_class", look_through: true))

    assert_in_delta 1000.0, (after - before).to_f, 0.01,
                    "the cash constituent did not reach liquidity; it was filed as unclassified"
  end

  private
    def liquidity_amount(segments)
      segments.find { |s| s.id == "liquidity" }&.amount&.amount || 0
    end

    def hold_another_security(index)
      security = Security.create!(
        ticker: "FILL#{index}", exchange_operating_mic: "XNAS",
        country_code: "US", sector: "Filler #{index}"
      )
      @account.holdings.create!(
        security: security, date: Date.current, qty: 1,
        price: 100, amount: 100, currency: "USD"
      )
    end

    def hold_foreign_security(index, currency)
      security = Security.create!(
        ticker: "FX#{currency}#{index}", exchange_operating_mic: "XNAS",
        country_code: "US", sector: "Foreign #{index}"
      )
      ExchangeRate.find_or_create_by!(
        from_currency: currency, to_currency: @family.currency, date: Date.current
      ) { |rate| rate.rate = 1.1 }
      @account.holdings.create!(
        security: security, date: Date.current, qty: 1,
        price: 100, amount: 100, currency: currency
      )
    end

    def count_queries
      count = 0
      sub = ActiveSupport::Notifications.subscribe("sql.active_record") do |_, _, _, _, payload|
        count += 1 unless payload[:name].to_s.in?([ "SCHEMA", "TRANSACTION" ])
      end
      yield
      count
    ensure
      ActiveSupport::Notifications.unsubscribe(sub)
    end

    def create_fund
      fund = Security.create!(
        ticker: "VWRA", name: "World ETF", exchange_operating_mic: "XLON",
        country_code: "GB", sector: "Fund wrapper"
      )
      @account.holdings.create!(
        security: fund, date: Date.current, qty: 10, price: 100, amount: 1000, currency: "USD"
      )
      fund
    end

    def fund_with_constituents
      fund = create_fund
      Security.create!(ticker: "MSFT2", exchange_operating_mic: "XNAS", country_code: "US", sector: "Technology")
      Security.create!(ticker: "JNJ2", exchange_operating_mic: "XNAS", country_code: "US", sector: "Healthcare")
      fund.constituents.create!(ticker: "MSFT2", name: "Microsoft", weight: 60)
      fund.constituents.create!(ticker: "JNJ2", name: "J&J", weight: 40)
      fund
    end
end
