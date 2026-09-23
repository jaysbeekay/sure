require "test_helper"

# 3.1 deliberately refuses to give an ETF an asset class -- a bond ETF and an
# equity ETF are the same wrapper around different things. The consequence is
# that a portfolio held through funds produces an allocation chart that is almost
# entirely "Unclassified", and misleading where it is not: someone holding VWRA
# and a US tech stock sees one equity slice, when their real technology exposure
# is the stock plus roughly a fifth of the fund.
#
# The load-bearing tests here are the skip gate (which decides whether the call
# happens at all, and is the whole cost of the feature) and the normalisation.
class Security::LookThroughTest < ActiveSupport::TestCase
  include ProviderTestHelper

  setup do
    @security = securities(:aapl)
    # Metadata present from the outset. `import_provider_details` refetches for
    # METADATA reasons when a name plus a logo or website is missing, and the
    # fixture has neither -- so without this the provider is called again for a
    # reason that has nothing to do with the constituents gate, and these tests
    # would be asserting the wrong thing.
    @security.update!(name: "Apple", logo_url: "https://example.com/aapl.png")
  end

  # --------------------------------------------------------------- the gate

  test "a fund is asked once, and not asked again" do
    provider = mock("provider")
    provider.stubs(:class).returns(Provider::TwelveData)
    provider.expects(:fetch_security_info).once.returns(
      provider_success_response(info(constituents: [ constituent("MSFT", "Microsoft", 10) ]))
    )
    @security.stubs(:price_data_provider).returns(provider)

    @security.import_provider_details(include_constituents: true)
    assert_equal 1, @security.reload.constituents.count

    second = mock("provider")
    second.expects(:fetch_security_info).never
    @security.stubs(:price_data_provider).returns(second)
    @security.import_provider_details(include_constituents: true)
  end

  # The negative, and the reason the gate is keyed on a timestamp rather than on
  # "does it have constituents". Most securities are not funds, so the provider
  # returns nothing for them -- and under a presence-keyed gate every one of them
  # would be re-asked on every sync, for ever.
  test "a security the provider has no holdings for is also not asked again" do
    import(info(constituents: nil))

    assert_empty @security.reload.constituents
    assert_not_nil @security.constituents_fetched_at, "nothing recorded that we asked"

    provider = mock("provider")
    provider.expects(:fetch_security_info).never
    @security.stubs(:price_data_provider).returns(provider)

    @security.import_provider_details(include_constituents: true)
  end

  # The importers walk every security on every sync, so a caller that has not
  # opted in must not inherit that cost -- the same reason
  # `include_classification:` defaults to false.
  test "a caller that has not opted in makes no provider call" do
    provider = mock("provider")
    provider.expects(:fetch_security_info).never
    @security.stubs(:price_data_provider).returns(provider)

    @security.import_provider_details

    assert_empty @security.reload.constituents
  end

  test "re-importing a fund replaces its holdings rather than duplicating them" do
    import(info(constituents: [ constituent("MSFT", "Microsoft", 10), constituent("AAPL", "Apple", 5) ]))
    @security.update!(constituents_fetched_at: nil)

    import(info(constituents: [ constituent("MSFT", "Microsoft", 12) ]))

    assert_equal [ "MSFT" ], @security.reload.constituents.pluck(:ticker)
    assert_equal BigDecimal("12"), @security.constituents.sole.weight
  end

  # --------------------------------------------------- what the weights mean

  # The figures deliberately sum to 99.4, not 100. A fund's reported holdings
  # routinely fall short -- cash, rounding, securities lending -- so code that
  # divides by 100 silently under-reports every constituent. Dividing by the
  # actual sum is the only thing that makes the expansion add up.
  test "weights are normalised against their actual sum, not against 100" do
    import(info(constituents: [
      constituent("MSFT", "Microsoft", 50.0),
      constituent("NVDA", "Nvidia", 30.0),
      constituent("TSLA", "Tesla", 19.4)
    ]))

    weights = @security.reload.look_through_weights

    assert_in_delta 1.0, weights.values.sum.to_f, 0.000001,
                    "the expansion does not add up to the whole fund"
    assert_in_delta 50.0 / 99.4, weights["MSFT"].to_f, 0.000001
    assert_in_delta 19.4 / 99.4, weights["TSLA"].to_f, 0.000001

    naive = 50.0 / 100
    assert_not_in_delta naive, weights["MSFT"].to_f, 0.000001,
                        "dividing by 100 would give the same answer, so this asserts nothing"
  end

  test "a security with no constituents looks through to nothing" do
    assert_empty @security.look_through_weights
  end

  test "a fund whose weights are all missing looks through to nothing" do
    @security.constituents.create!(ticker: "MSFT", name: "Microsoft", weight: nil)

    assert_empty @security.look_through_weights
  end

  # A fund whose every reported weight is 0 is the only way the sum can be zero
  # with rows present, so it is the only case that reaches the divide. Without
  # the guard this raises ZeroDivisionError rather than declining to answer.
  test "a fund whose weights are all zero declines to answer rather than dividing" do
    @security.constituents.create!(ticker: "MSFT", name: "Microsoft", weight: 0)
    @security.constituents.create!(ticker: "NVDA", name: "Nvidia", weight: 0)

    result = nil
    assert_nothing_raised { result = @security.look_through_weights }
    assert_empty result
  end

  # The defect that boundary hides. EODHD rounds `Assets_%`, so a position too
  # small to round up to 0.01 comes back as 0 -- and a validation refusing zero
  # made `create!` raise inside `store_constituents`, taking the whole fund's
  # holdings down with it.
  test "a negligible holding reported as zero does not lose the rest of the fund" do
    import(info(constituents: [
      constituent("MSFT", "Microsoft", 60.0),
      constituent("TINY", "Negligible Co", 0),
      constituent("NVDA", "Nvidia", 40.0)
    ]))

    assert_equal 3, @security.reload.constituents.count,
                 "a zero-weight holding aborted the whole import"
    assert_in_delta 0.6, @security.look_through_weights["MSFT"].to_f, 0.000001
  end

  private
    def constituent(ticker, name, weight)
      { ticker: ticker, name: name, weight: weight }
    end

    def info(constituents:)
      Provider::SecurityConcept::SecurityInfo.new(
        symbol: "AAPL", name: nil, links: nil, logo_url: nil, description: nil,
        kind: nil, exchange_operating_mic: "XNAS", constituents: constituents
      )
    end

    def import(data)
      provider = mock("provider")
      provider.stubs(:class).returns(Provider::TwelveData)
      provider.stubs(:fetch_security_info).returns(provider_success_response(data))
      @security.stubs(:price_data_provider).returns(provider)
      @security.import_provider_details(include_constituents: true)
    end
end
