require "test_helper"

# Providers already fetch the payload that carries sector and industry — EODHD's
# `General`, Alpha Vantage's `OVERVIEW`, Yahoo's `assetProfile` — and we throw it
# away. This carries it through instead, so it costs no additional provider call.
#
# Two things here are load-bearing and neither is the happy path: the skip gate,
# which decides whether the call happens at all, and the precedence rules, which
# decide whether what comes back may be written.
class Security::ClassificationIngestionTest < ActiveSupport::TestCase
  include ProviderTestHelper

  setup do
    @security = securities(:aapl)
  end

  # ------------------------------------------------------------ the skip gate

  # The assertion that fails without the gate change, and the whole reason the
  # slice is not a no-op. Most securities already have a name and a logo, so
  # under the old gate they never refetched and classification would have
  # landed only on newly created ones.
  test "a security with metadata but no classification is still asked, when classification is wanted" do
    @security.update!(name: "Apple", logo_url: "https://example.com/aapl.png")
    provider = stub_provider(info(sector: "Technology", industry: "Consumer Electronics"))

    provider.expects(:fetch_security_info).once.returns(
      provider_success_response(info(sector: "Technology", industry: "Consumer Electronics"))
    )
    @security.stubs(:price_data_provider).returns(provider)

    @security.import_provider_details(include_classification: true)

    assert_equal "Technology", @security.reload.sector
  end

  # The mirror. Once the provider has answered, the gate closes, so this is one
  # call per security rather than one per sync forever.
  test "a security that already has sector and industry is not asked again" do
    @security.update!(
      name: "Apple", logo_url: "https://example.com/aapl.png",
      sector: "Technology", industry: "Consumer Electronics"
    )
    provider = capable_provider("provider")
    provider.expects(:fetch_security_info).never
    @security.stubs(:price_data_provider).returns(provider)

    @security.import_provider_details(include_classification: true)
  end

  # The case that made keying the gate on `classification_source` wrong in both
  # directions. An ETF is deliberately left without an asset class -- the
  # wrapper does not imply one -- so it never gets a source. Keyed on the
  # source, the gate would have stayed open and asked the provider again on
  # every sync, for ever. Keyed on what the provider actually supplies, its
  # answer closes the gate.
  test "a wrapper the type map will not classify is still only asked once" do
    @security.update!(name: "Apple", logo_url: "https://example.com/aapl.png")
    import(info(kind: "ETF", sector: "Technology", industry: "Consumer Electronics"))

    assert_nil @security.reload.classification_source, "an ETF is deliberately left unsourced"

    provider = capable_provider("provider")
    provider.expects(:fetch_security_info).never
    @security.stubs(:price_data_provider).returns(provider)

    @security.import_provider_details(include_classification: true)
  end

  # The other direction, and the reason the gate needs BOTH halves. A `default`
  # is written by 3.2 for cash, crypto and region -- things classified from
  # their own shape, which no provider has a sector for. `price_data_provider`
  # falls back to the first configured provider, which answers nothing for a
  # crypto pair, so opening the gate on a blank sector alone would ask on every
  # sync for ever, on exactly the securities a provider cannot help with.
  test "a default classification closes the gate, since no provider improves on it" do
    @security.update!(
      name: "Apple", logo_url: "https://example.com/aapl.png",
      asset_class: "alternative_investment", asset_sub_class: "cryptocurrency",
      classification_source: "default"
    )
    provider = capable_provider("provider")
    provider.expects(:fetch_security_info).never
    @security.stubs(:price_data_provider).returns(provider)

    @security.import_provider_details(include_classification: true)
  end

  # A user who has answered is not asked again, whatever is still missing.
  test "a manually classified security is not asked again" do
    @security.update!(name: "Apple", logo_url: "https://example.com/aapl.png",
                      asset_class: "equity", classification_source: "manual")
    provider = capable_provider("provider")
    provider.expects(:fetch_security_info).never
    @security.stubs(:price_data_provider).returns(provider)

    @security.import_provider_details(include_classification: true)
  end

  # The reason `include_classification` defaults to false. The unbounded shape
  # is the importers' cadence -- they walk every security on every sync -- so a
  # caller that has not opted in must not widen the gate and inherit that cost.
  # `HoldingsController#sync_prices` is the one such caller: a POST behind
  # `require_holding_write_permission!`, where the user asked for prices rather
  # than for classification.
  test "a caller that has not opted in makes no provider call" do
    @security.update!(name: "Apple", logo_url: "https://example.com/aapl.png")
    provider = capable_provider("provider")
    provider.expects(:fetch_security_info).never
    @security.stubs(:price_data_provider).returns(provider)

    @security.import_provider_details

    assert_nil @security.reload.sector
  end

  test "a locked security is not asked, even when it has no classification" do
    @security.update!(name: "Apple", logo_url: "https://example.com/aapl.png", classification_locked: true)
    provider = capable_provider("provider")
    provider.expects(:fetch_security_info).never
    @security.stubs(:price_data_provider).returns(provider)

    @security.import_provider_details(include_classification: true)
  end

  # The gate is not the only thing protecting a locked security, and it cannot
  # be: a locked security that is missing its NAME still fetches, for metadata
  # reasons, and the response carries classification whether we asked for it or
  # not. The write itself has to refuse as well. Without the guard inside
  # `classification_attributes_from` this is where the lock leaks.
  test "a locked security fetched for its metadata is still not classified" do
    @security.update!(name: nil, logo_url: nil, website_url: nil, classification_locked: true)
    @security.stubs(:price_data_provider).returns(
      stub_provider(info(kind: "Common Stock", sector: "Technology", industry: "Consumer Electronics"))
    )

    @security.import_provider_details

    @security.reload
    assert_nil @security.asset_class, "the lock leaked: a locked security was classified"
    assert_nil @security.sector
    assert_nil @security.classification_source
  end

  # --------------------------------------------------------- what is written

  test "sector and industry are taken from the provider" do
    import(info(sector: "Technology", industry: "Consumer Electronics"))

    assert_equal "Technology", @security.reload.sector
    assert_equal "Consumer Electronics", @security.industry
  end

  test "a common stock is classified as equity, and the provider is recorded as the source" do
    import(info(kind: "Common Stock"))

    assert_equal "equity", @security.reload.asset_class
    assert_equal "stock", @security.asset_sub_class
    assert_equal "provider", @security.classification_source
  end

  # A bond ETF and an equity ETF are the same wrapper around different asset
  # classes. Answering "equity" for both would put a figure in the allocation
  # chart that nothing supports, so the wrapper types are left for 3.7.
  test "an ETF is not given an asset class, because its wrapper does not imply one" do
    import(info(kind: "ETF", sector: "Technology"))

    assert_nil @security.reload.asset_class
    assert_nil @security.classification_source
    assert_equal "Technology", @security.sector, "sector is still carried through"
  end

  test "a provider that returns no classification writes nothing" do
    import(info)

    assert_nil @security.reload.sector
    assert_nil @security.industry
    assert_nil @security.asset_class
  end

  # ---------------------------------------------------------- precedence

  test "a manual classification is not replaced by a provider" do
    @security.update!(asset_class: "fixed_income", asset_sub_class: "bond", classification_source: "manual")

    import(info(kind: "Common Stock"))

    assert_equal "fixed_income", @security.reload.asset_class
    assert_equal "manual", @security.classification_source
  end

  # The provider outranks a default: a default is what we guessed from the
  # instrument's shape, and the provider actually knows.
  test "a default classification is replaced by a provider" do
    @security.update!(asset_class: "equity", asset_sub_class: "etf", classification_source: "default")

    import(info(kind: "Common Stock"))

    assert_equal "stock", @security.reload.asset_sub_class
    assert_equal "provider", @security.classification_source
  end

  test "a sector a user already corrected is not restated" do
    @security.update!(sector: "Hand-picked", classification_source: "manual")

    import(info(sector: "Technology", industry: "Consumer Electronics"))

    assert_equal "Hand-picked", @security.reload.sector
    assert_equal "Consumer Electronics", @security.industry, "an empty field is still filled"
  end

  # ------------------------------------------------------- the blast radius

  # SecurityInfo is a Data with eleven implementers. Eight of them are not
  # wired here and still construct it with the original seven arguments; if the
  # new fields had no defaults, every one of them would raise.
  test "the original seven arguments still construct a SecurityInfo" do
    built = Provider::SecurityConcept::SecurityInfo.new(
      symbol: "AAPL", name: "Apple", links: nil, logo_url: nil,
      description: nil, kind: "Common Stock", exchange_operating_mic: "XNAS"
    )

    assert_nil built.sector
    assert_nil built.industry
  end

  # The folded-in half of #212. The classification gate has no timestamp at all:
  # it closes only when `classification_source`, `sector` or `industry` fills.
  # A provider that supplies none of them never closes it, so that security was
  # re-asked on EVERY sync, for ever -- the opposite failure to the constituents
  # gate, from the same missing fact about what the provider can answer.
  test "a provider that cannot classify is not asked again and again" do
    # Metadata present from the outset, or `import_provider_details` refetches
    # for a METADATA reason -- a missing name plus logo -- and the test would be
    # asserting something other than the classification gate. Same precaution
    # `Security::LookThroughTest` takes in its setup, for the same reason.
    @security.update!(name: "Apple", logo_url: "https://example.com/aapl.png")

    incapable = capable_provider("incapable", classification: false, constituents: false)
    incapable.stubs(:class).returns(Provider::TwelveData)
    incapable.expects(:fetch_security_info).never
    @security.stubs(:price_data_provider).returns(incapable)

    @security.import_provider_details(include_classification: true)

    assert_nil @security.reload.sector, "an incapable provider somehow classified the security"
  end

  # The other side, so the fix is not "never classify".
  test "a provider that can classify is still asked" do
    @security.update!(name: "Apple", logo_url: "https://example.com/aapl.png")

    capable = capable_provider("capable")
    capable.stubs(:class).returns(Provider::Eodhd)
    capable.expects(:fetch_security_info).once.returns(
      provider_success_response(
        Provider::SecurityConcept::SecurityInfo.new(
          symbol: "AAPL", name: nil, links: nil, logo_url: nil, description: nil,
          kind: nil, exchange_operating_mic: "XNAS", sector: "Technology", industry: "Consumer Electronics"
        )
      )
    )
    @security.stubs(:price_data_provider).returns(capable)

    @security.import_provider_details(include_classification: true)

    assert_equal "Technology", @security.reload.sector
  end

  private
    def info(sector: nil, industry: nil, kind: nil)
      Provider::SecurityConcept::SecurityInfo.new(
        symbol: "AAPL", name: nil, links: nil, logo_url: nil, description: nil,
        kind: kind, exchange_operating_mic: "XNAS", sector: sector, industry: industry
      )
    end

    def stub_provider(data)
      provider = capable_provider("provider")
      provider.stubs(:class).returns(Provider::TwelveData)
      provider.stubs(:fetch_security_info).returns(provider_success_response(data))
      provider
    end

    def import(data)
      @security.stubs(:price_data_provider).returns(stub_provider(data))
      @security.import_provider_details(include_classification: true)
    end
end
