module ProviderTestHelper
  def provider_success_response(data)
    Provider::Response.new(
      success?: true,
      data: data,
      error: nil
    )
  end

  # A provider mock that DECLARES it can answer for constituents and for
  # classification.
  #
  # Since #212 both fetches are gated on the provider's own declaration, so a
  # bare `mock("provider")` is an INCAPABLE provider: it is never asked, and a
  # test expecting a fetch fails. That is the right default -- nine of the ten
  # real providers supply neither -- but it means a test that wants the fetch to
  # happen has to say so, which is what this is for.
  #
  # Pass `constituents:` or `classification:` false to build the incapable side
  # of a boundary deliberately.
  def capable_provider(name = "provider", constituents: true, classification: true)
    provider = mock(name)
    provider.stubs(:supplies_constituents?).returns(constituents)
    provider.stubs(:supplies_classification?).returns(classification)
    provider
  end

  def provider_error_response(error)
    Provider::Response.new(
      success?: false,
      data: nil,
      error: error
    )
  end

  # The errors a provider hands its default_error_transformer, so a test can
  # check which failure produced a failed response, not only that one did.
  def capture_transformed_errors(provider)
    seen = []
    provider.singleton_class.prepend(Module.new do
      define_method(:default_error_transformer) do |error|
        seen << error
        super(error)
      end
    end)
    seen
  end

  # The read timeout each request a provider sends carries, in order, so a test
  # can check a per-request override, not only the client's default.
  def capture_request_timeouts(provider)
    seen = []
    recorder = Class.new(Faraday::Middleware) do
      define_method(:on_request) { |env| seen << env.request.timeout }
    end
    provider.send(:client).builder.insert(0, recorder)
    seen
  end
end
