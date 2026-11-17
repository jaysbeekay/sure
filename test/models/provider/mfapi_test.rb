require "test_helper"

class Provider::MfapiTest < ActiveSupport::TestCase
  include ProviderTestHelper

  test "client sets explicit open and read timeouts" do
    provider = Provider::Mfapi.new
    options = provider.send(:client).options

    assert_equal 5, options.open_timeout
    assert_equal 20, options.timeout
  end

  test "a timed-out request returns a failed response with the provider's Error" do
    provider = Provider::Mfapi.new
    provider.stubs(:throttle_request)
    Faraday::Retry::Middleware.any_instance.stubs(:sleep)
    search = stub_request(:get, %r{\Ahttps://api\.mfapi\.in/mf/search}).to_timeout
    errors = capture_transformed_errors(provider)

    response = provider.search_securities("TEST")

    assert_not response.success?
    assert_instance_of Provider::Mfapi::Error, response.error
    assert_requested search, times: 4
    assert_kind_of Faraday::ConnectionFailed, errors.last
    assert_kind_of Net::OpenTimeout, errors.last.wrapped_exception
  end

  test "a read timeout is retried and returns a failed response with the provider's Error" do
    provider = Provider::Mfapi.new
    provider.stubs(:throttle_request)
    Faraday::Retry::Middleware.any_instance.stubs(:sleep)
    search = stub_request(:get, %r{\Ahttps://api\.mfapi\.in/mf/search}).to_raise(Net::ReadTimeout)
    errors = capture_transformed_errors(provider)

    response = provider.search_securities("TEST")

    assert_not response.success?
    assert_instance_of Provider::Mfapi::Error, response.error
    assert_requested search, times: 4
    assert_kind_of Faraday::TimeoutError, errors.last
  end

  test "search_securities maps each match to an Indian mutual fund" do
    stub_mfapi("/mf/search", { "q" => "HDFC" }, [
      { "schemeCode" => 119551, "schemeName" => "HDFC Flexi Cap Fund - Direct Plan - Growth" },
      { "schemeCode" => 101762, "schemeName" => "HDFC Flexi Cap Fund - Regular Plan - Growth" }
    ])

    response = build_provider.search_securities("HDFC")

    assert response.success?
    assert_equal [ "119551", "101762" ], response.data.map(&:symbol)
    assert_equal "HDFC Flexi Cap Fund - Direct Plan - Growth", response.data.first.name
    assert_equal [ [ "XBOM", "IN", "INR" ] ],
      response.data.map { |security| [ security.exchange_operating_mic, security.country_code, security.currency ] }.uniq
  end

  test "search_securities with a non-array body returns a failed response" do
    stub_mfapi("/mf/search", {}, { "unexpected" => true })

    response = nil
    assert_nothing_raised { response = build_provider.search_securities("HDFC") }

    assert_not response.success?
    assert_instance_of Provider::Mfapi::Error, response.error
    assert_equal "Unexpected response format from search endpoint", response.error.message
  end

  test "fetch_security_info maps the latest scheme meta" do
    stub_mfapi("/mf/119551/latest", {}, {
      "meta" => {
        "scheme_name" => "HDFC Flexi Cap Fund - Direct Plan - Growth",
        "fund_house" => "HDFC Mutual Fund",
        "scheme_category" => "Equity Scheme - Flexi Cap Fund"
      },
      "data" => [ { "date" => "08-03-2024", "nav" => "1650.12300" } ],
      "status" => "SUCCESS"
    })

    response = build_provider.fetch_security_info(symbol: "119551", exchange_operating_mic: "XBOM")

    assert response.success?
    info = response.data
    assert_equal [ "119551", "HDFC Flexi Cap Fund - Direct Plan - Growth", "mutual fund", "XBOM" ],
      [ info.symbol, info.name, info.kind, info.exchange_operating_mic ]
    assert_equal "HDFC Mutual Fund - Equity Scheme - Flexi Cap Fund", info.description
  end

  test "fetch_security_prices parses DD-MM-YYYY dates and skips zero, missing and undated NAVs" do
    stub_mfapi("/mf/119551", { "startDate" => "2024-01-25", "endDate" => "2024-02-05" }, {
      "data" => [
        { "date" => "02-02-2024", "nav" => "0.00000" },
        { "date" => "", "nav" => "1500.00000" },
        { "date" => "01-02-2024", "nav" => nil },
        { "date" => "01-02-2024", "nav" => "1490.25000" }
      ]
    })

    response = build_provider.fetch_security_prices(
      symbol: "119551", exchange_operating_mic: "XBOM", start_date: Date.new(2024, 1, 25), end_date: Date.new(2024, 2, 5)
    )

    assert response.success?
    assert_equal [ [ Date.new(2024, 2, 1), 1490.25, "INR", "119551" ] ],
      response.data.map { |price| [ price.date, price.price, price.currency, price.symbol ] }
  end

  test "fetch_security_prices without data returns a failed response" do
    stub_mfapi("/mf/119551", {}, { "meta" => {} })

    response = build_provider.fetch_security_prices(
      symbol: "119551", exchange_operating_mic: "XBOM", start_date: Date.new(2024, 1, 25), end_date: Date.new(2024, 2, 5)
    )

    assert_not response.success?
    # RateLimitable#default_error_transformer re-wraps InvalidSecurityPriceError as the base Error.
    assert_kind_of Provider::Mfapi::Error, response.error
    assert_equal "No NAV data returned for scheme 119551", response.error.message
  end

  test "fetch_security_price looks back seven days and returns the nearest earlier NAV" do
    stub_mfapi("/mf/119551", { "startDate" => "2024-02-29", "endDate" => "2024-03-07" }, {
      "data" => [
        { "date" => "08-03-2024", "nav" => "1650.00000" },
        { "date" => "05-03-2024", "nav" => "1640.00000" },
        { "date" => "04-03-2024", "nav" => "1630.00000" }
      ]
    })

    response = build_provider.fetch_security_price(symbol: "119551", exchange_operating_mic: "XBOM", date: Date.new(2024, 3, 7))

    assert response.success?
    assert_equal [ Date.new(2024, 3, 5), 1640.0 ], [ response.data.date, response.data.price ]
  end

  test "fetch_security_price with no NAV in the window returns a failed response" do
    stub_mfapi("/mf/119551", {}, { "data" => [] })

    response = build_provider.fetch_security_price(symbol: "119551", exchange_operating_mic: "XBOM", date: Date.new(2024, 3, 7))

    assert_not response.success?
    # RateLimitable#default_error_transformer re-wraps InvalidSecurityPriceError as the base Error.
    assert_kind_of Provider::Mfapi::Error, response.error
    assert_equal "No NAV found for scheme 119551 on or before 2024-03-07", response.error.message
  end

  test "an ERROR status body maps to Error with the API message" do
    stub_mfapi("/mf/search", {}, { "status" => "ERROR", "message" => "boom" })

    response = nil
    assert_nothing_raised { response = build_provider.search_securities("HDFC") }

    assert_not response.success?
    assert_instance_of Provider::Mfapi::Error, response.error
    assert_match(/\AAPI error: /, response.error.message)
  end

  test "a FAIL status body maps to Error" do
    stub_mfapi("/mf/119551/latest", {}, { "status" => "FAIL" })

    response = nil
    assert_nothing_raised { response = build_provider.fetch_security_info(symbol: "119551", exchange_operating_mic: "XBOM") }

    assert_not response.success?
    assert_instance_of Provider::Mfapi::Error, response.error
    assert_equal "API error: FAIL", response.error.message
  end

  test "an HTTP 500 maps to Error" do
    stub_request(:get, %r{\Ahttps://api\.mfapi\.in/mf/search}).to_return(status: 500, body: "")

    response = build_provider.search_securities("HDFC")

    assert_not response.success?
    assert_instance_of Provider::Mfapi::Error, response.error
  end

  private
    def build_provider
      provider = Provider::Mfapi.new
      provider.stubs(:throttle_request)
      provider
    end

    def stub_mfapi(path, params, body)
      stub_request(:get, "https://api.mfapi.in#{path}")
        .with(query: hash_including(params))
        .to_return(status: 200, body: body.to_json, headers: { "Content-Type" => "application/json" })
    end
end
