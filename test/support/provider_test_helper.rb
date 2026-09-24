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
end
