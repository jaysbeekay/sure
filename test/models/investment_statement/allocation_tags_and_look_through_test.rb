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
  test "an untagged holding falls into the unclassified bucket" do
    segments = @statement.allocation_by("tag")

    assert segments.any? { |s| s.id == InvestmentStatement::UNCLASSIFIED },
           "an untagged holding vanished from the allocation"
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

  private
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
