require "test_helper"

class Provider::AlphaVantageTest < ActiveSupport::TestCase
  include ProviderTestHelper

  OVERVIEW_URL = "https://www.alphavantage.co/query".freeze

  setup do
    @provider = Provider::AlphaVantage.new("test_api_key")
  end

  # The test environment caches in a null store, so the usage readers need a real
  # RedisCacheStore to notice a counter they cannot read back. The per-run namespace
  # keeps runs sharing one Redis from reading each other's counts.
  test "usage reports the request counter on a real Redis cache" do
    store = ActiveSupport::Cache::RedisCacheStore.new(
      url: ENV.fetch("REDIS_URL", "redis://localhost:6379"),
      namespace: "test:alpha_vantage:#{SecureRandom.hex(8)}"
    )
    Rails.stubs(:cache).returns(store)

    provider = Provider::AlphaVantage.new("test_api_key")
    provider.define_singleton_method(:sleep) { |_duration| }
    2.times { provider.send(:throttle_request) }

    assert_equal 2, provider.usage.data.used
  ensure
    store&.delete("alpha_vantage:daily:#{Date.current}")
  end

  test "every attempt of a request is counted against the daily limit, including retries" do
    Rails.stubs(:cache).returns(ActiveSupport::Cache::MemoryStore.new)
    @provider.stubs(:sleep)
    Faraday::Retry::Middleware.any_instance.stubs(:sleep)

    stub_request(:get, OVERVIEW_URL)
      .with(query: hash_including("function" => "OVERVIEW"))
      .to_raise(Faraday::TimeoutError).then
      .to_raise(Faraday::TimeoutError).then
      .to_return(status: 200, body: { "Name" => "Apple Inc", "Symbol" => "AAPL" }.to_json)

    assert @provider.fetch_security_info(symbol: "AAPL", exchange_operating_mic: "XNYS").success?

    assert_requested :get, OVERVIEW_URL, query: hash_including("function" => "OVERVIEW"), times: 3
    assert_equal 3, Rails.cache.read("alpha_vantage:daily:#{Date.current}")
  end

  test "a retry that would exceed the daily limit is refused before reaching Alpha Vantage" do
    store = ActiveSupport::Cache::MemoryStore.new
    Rails.stubs(:cache).returns(store)
    @provider.stubs(:sleep)
    Faraday::Retry::Middleware.any_instance.stubs(:sleep)
    store.write("alpha_vantage:daily:#{Date.current}", 24)

    stub_request(:get, OVERVIEW_URL)
      .with(query: hash_including("function" => "OVERVIEW"))
      .to_raise(Faraday::TimeoutError)

    result = @provider.fetch_security_info(symbol: "AAPL", exchange_operating_mic: "XNYS")

    assert_not result.success?
    assert_kind_of Provider::AlphaVantage::RateLimitError, result.error
    # The first attempt is counted (24 -> 25) and reaches the wire; the retry is counted
    # past the limit (25 -> 26) and refused before it
    assert_requested :get, OVERVIEW_URL, query: hash_including("function" => "OVERVIEW"), times: 1
    assert_equal 26, store.read("alpha_vantage:daily:#{Date.current}")
  end

  test "client sets explicit open and read timeouts" do
    provider = Provider::AlphaVantage.new("test_api_key")
    options = provider.send(:client).options

    assert_equal 5, options.open_timeout
    assert_equal 20, options.timeout
  end

  test "a timed-out request returns a failed response with the provider's Error" do
    provider = Provider::AlphaVantage.new("test_api_key")
    provider.stubs(:throttle_request)
    Faraday::Retry::Middleware.any_instance.stubs(:sleep)
    search = stub_request(:get, "https://www.alphavantage.co/query")
      .with(query: hash_including("function" => "SYMBOL_SEARCH")).to_timeout
    errors = capture_transformed_errors(provider)

    response = provider.search_securities("TEST")

    assert_not response.success?
    assert_instance_of Provider::AlphaVantage::Error, response.error
    assert_requested search, times: 4
    assert_kind_of Faraday::ConnectionFailed, errors.last
    assert_kind_of Net::OpenTimeout, errors.last.wrapped_exception
  end

  test "a read timeout is retried and returns a failed response with the provider's Error" do
    provider = Provider::AlphaVantage.new("test_api_key")
    provider.stubs(:throttle_request)
    Faraday::Retry::Middleware.any_instance.stubs(:sleep)
    search = stub_request(:get, "https://www.alphavantage.co/query")
      .with(query: hash_including("function" => "SYMBOL_SEARCH")).to_raise(Net::ReadTimeout)
    errors = capture_transformed_errors(provider)

    response = provider.search_securities("TEST")

    assert_not response.success?
    assert_instance_of Provider::AlphaVantage::Error, response.error
    assert_requested search, times: 4
    assert_kind_of Faraday::TimeoutError, errors.last
  end

  test "search_securities strips the exchange suffix and maps it to a MIC" do
    stub_av_query({ "function" => "SYMBOL_SEARCH", "keywords" => "CSPX" }, search_body)

    response = build_provider.search_securities("CSPX")

    assert response.success?
    cspx, aapl = response.data
    assert_equal [ "CSPX", "iShares Core S&P 500 UCITS ETF", "XLON", "GB", "GBP" ],
      [ cspx.symbol, cspx.name, cspx.exchange_operating_mic, cspx.country_code, cspx.currency ]
    assert_equal [ "AAPL", nil, "US", "USD" ],
      [ aapl.symbol, aapl.exchange_operating_mic, aapl.country_code, aapl.currency ]
  end

  test "search_securities caches each match's currency under the suffixed Alpha Vantage ticker" do
    Rails.stubs(:cache).returns(ActiveSupport::Cache::MemoryStore.new)
    stub_av_query({ "function" => "SYMBOL_SEARCH" }, search_body)

    build_provider.search_securities("CSPX")

    assert_equal "GBP", Rails.cache.read("alpha_vantage:currency:CSPX.LON")
    assert_nil Rails.cache.read("alpha_vantage:currency:CSPX")
  end

  test "search_securities without bestMatches returns a failed response" do
    stub_av_query({ "function" => "SYMBOL_SEARCH" }, {})

    response = nil
    assert_nothing_raised { response = build_provider.search_securities("CSPX") }

    assert_not response.success?
    assert_instance_of Provider::AlphaVantage::Error, response.error
    assert_equal "No data returned from search endpoint", response.error.message
  end

  test "fetch_security_info requests the suffixed ticker and maps the overview" do
    stub_av_query(
      { "function" => "OVERVIEW", "symbol" => "CSPX.LON" },
      {
        "Symbol" => "CSPX.LON",
        "Name" => "iShares Core S&P 500 UCITS ETF",
        "AssetType" => "ETF",
        "Description" => "Tracks the S&P 500.",
        "OfficialSite" => "https://www.ishares.com"
      }
    )

    response = build_provider.fetch_security_info(symbol: "CSPX", exchange_operating_mic: "XLON")

    assert response.success?
    info = response.data
    assert_equal [ "iShares Core S&P 500 UCITS ETF", "etf", "Tracks the S&P 500.", "https://www.ishares.com", "XLON" ],
      [ info.name, info.kind, info.description, info.links, info.exchange_operating_mic ]
  end

  test "fetch_security_info with a blank Name returns a failed response" do
    stub_av_query({ "function" => "OVERVIEW" }, { "Symbol" => "CSPX.LON", "Name" => "" })

    response = build_provider.fetch_security_info(symbol: "CSPX", exchange_operating_mic: "XLON")

    assert_not response.success?
    assert_instance_of Provider::AlphaVantage::Error, response.error
    assert_equal "No metadata returned for symbol CSPX.LON", response.error.message
  end

  test "fetch_security_prices keeps only rows inside the window and prices a LON listing in GBP" do
    stub_av_query(
      { "function" => "TIME_SERIES_DAILY", "symbol" => "CSPX.LON", "outputsize" => "compact" },
      daily_body("2024-08-05" => "103.00", "2024-08-02" => "102.00", "2024-08-01" => "101.00", "2024-07-31" => "100.00")
    )

    response = build_provider.fetch_security_prices(
      symbol: "CSPX", exchange_operating_mic: "XLON", start_date: Date.new(2024, 8, 1), end_date: Date.new(2024, 8, 2)
    )

    assert response.success?
    assert_equal [ Date.new(2024, 8, 2), Date.new(2024, 8, 1) ], response.data.map(&:date)
    assert_equal [ 102, 101 ], response.data.map { |price| price.price.to_d }
    assert_equal [ "GBP" ], response.data.map(&:currency).uniq
    assert_equal [ "CSPX" ], response.data.map(&:symbol).uniq
  end

  test "fetch_security_prices requests a US listing without a suffix and prices it in USD" do
    stub_av_query({ "function" => "TIME_SERIES_DAILY", "symbol" => "AAPL" }, daily_body("2024-08-01" => "218.36"))

    response = build_provider.fetch_security_prices(
      symbol: "AAPL", exchange_operating_mic: "XNAS", start_date: Date.new(2024, 8, 1), end_date: Date.new(2024, 8, 1)
    )

    assert response.success?
    assert_equal [ "USD" ], response.data.map(&:currency)
  end

  test "fetch_security_prices prices in a cached currency over the suffix default" do
    Rails.stubs(:cache).returns(ActiveSupport::Cache::MemoryStore.new)
    Rails.cache.write("alpha_vantage:currency:CSPX.LON", "USD")
    stub_av_query({ "function" => "TIME_SERIES_DAILY", "symbol" => "CSPX.LON" }, daily_body("2024-08-01" => "101.00"))

    response = build_provider.fetch_security_prices(
      symbol: "CSPX", exchange_operating_mic: "XLON", start_date: Date.new(2024, 8, 1), end_date: Date.new(2024, 8, 1)
    )

    assert response.success?
    assert_equal [ "USD" ], response.data.map(&:currency)
  end

  test "fetch_security_prices skips a zero close inside the window" do
    stub_av_query({ "function" => "TIME_SERIES_DAILY" }, daily_body("2024-08-02" => "102.00", "2024-08-01" => "0.0000"))

    response = build_provider.fetch_security_prices(
      symbol: "CSPX", exchange_operating_mic: "XLON", start_date: Date.new(2024, 8, 1), end_date: Date.new(2024, 8, 2)
    )

    assert response.success?
    assert_equal [ Date.new(2024, 8, 2) ], response.data.map(&:date)
  end

  test "fetch_security_prices without a time series returns a failed response" do
    stub_av_query({ "function" => "TIME_SERIES_DAILY" }, { "Meta Data" => {} })

    response = build_provider.fetch_security_prices(
      symbol: "CSPX", exchange_operating_mic: "XLON", start_date: Date.new(2024, 8, 1), end_date: Date.new(2024, 8, 2)
    )

    assert_not response.success?
    # RateLimitable#default_error_transformer re-wraps InvalidSecurityPriceError as the base Error.
    assert_kind_of Provider::AlphaVantage::Error, response.error
    assert_equal "No time series data returned for symbol CSPX.LON", response.error.message
  end

  test "fetch_security_price returns the row for the requested day" do
    stub_av_query(
      { "function" => "TIME_SERIES_DAILY" },
      daily_body("2024-08-05" => "103.00", "2024-08-02" => "102.00", "2024-08-01" => "101.00")
    )

    response = build_provider.fetch_security_price(symbol: "CSPX", exchange_operating_mic: "XLON", date: Date.new(2024, 8, 2))

    assert response.success?
    assert_equal [ Date.new(2024, 8, 2), 102 ], [ response.data.date, response.data.price.to_d ]
  end

  test "fetch_security_price with no row for the day returns a failed response" do
    stub_av_query({ "function" => "TIME_SERIES_DAILY" }, daily_body("2024-08-02" => "102.00"))

    response = build_provider.fetch_security_price(symbol: "CSPX", exchange_operating_mic: "XLON", date: Date.new(2024, 8, 3))

    assert_not response.success?
    # RateLimitable#default_error_transformer re-wraps InvalidSecurityPriceError as the base Error.
    assert_kind_of Provider::AlphaVantage::Error, response.error
    assert_equal "No prices found for security CSPX on date 2024-08-03", response.error.message
  end

  test "a Note body maps to RateLimitError" do
    stub_av_query({ "function" => "SYMBOL_SEARCH" }, { "Note" => "Thank you for using Alpha Vantage!" })

    response = nil
    assert_nothing_raised { response = build_provider.search_securities("CSPX") }

    assert_not response.success?
    assert_instance_of Provider::AlphaVantage::RateLimitError, response.error
    assert_equal "Thank you for using Alpha Vantage!", response.error.message
  end

  test "an Information body maps to RateLimitError" do
    stub_av_query({ "function" => "SYMBOL_SEARCH" }, { "Information" => "Daily rate limit reached." })

    response = nil
    assert_nothing_raised { response = build_provider.search_securities("CSPX") }

    assert_not response.success?
    assert_instance_of Provider::AlphaVantage::RateLimitError, response.error
    assert_equal "Daily rate limit reached.", response.error.message
  end

  test "an Error Message body maps to Error with the API message" do
    stub_av_query({ "function" => "SYMBOL_SEARCH" }, { "Error Message" => "Invalid API call." })

    response = nil
    assert_nothing_raised { response = build_provider.search_securities("CSPX") }

    assert_not response.success?
    assert_instance_of Provider::AlphaVantage::Error, response.error
    assert_match(/\AAPI error: /, response.error.message)
  end

  test "an HTTP 500 maps to Error" do
    stub_request(:get, %r{\Ahttps://www\.alphavantage\.co/query}).to_return(status: 500, body: "")

    response = build_provider.search_securities("CSPX")

    assert_not response.success?
    assert_instance_of Provider::AlphaVantage::Error, response.error
  end

  test "an HTTP 429 maps to RateLimitError" do
    stub_request(:get, %r{\Ahttps://www\.alphavantage\.co/query}).to_return(status: 429, body: "")

    response = build_provider.search_securities("CSPX")

    assert_not response.success?
    assert_instance_of Provider::AlphaVantage::RateLimitError, response.error
  end

  private
    def build_provider
      provider = Provider::AlphaVantage.new("test_api_key")
      provider.stubs(:throttle_request)
      provider
    end

    def stub_av_query(params, body)
      stub_request(:get, "https://www.alphavantage.co/query")
        .with(query: hash_including(params.merge("apikey" => "test_api_key")))
        .to_return(status: 200, body: body.to_json, headers: { "Content-Type" => "application/json" })
    end

    def search_body
      {
        "bestMatches" => [
          { "1. symbol" => "CSPX.LON", "2. name" => "iShares Core S&P 500 UCITS ETF", "4. region" => "United Kingdom", "8. currency" => "GBP" },
          { "1. symbol" => "AAPL", "2. name" => "Apple Inc", "4. region" => "United States", "8. currency" => "USD" }
        ]
      }
    end

    def daily_body(closes)
      { "Time Series (Daily)" => closes.transform_values { |close| { "4. close" => close } } }
    end
end
