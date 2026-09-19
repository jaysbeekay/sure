module Provider::SecurityConcept
  extend ActiveSupport::Concern

  # NOTE: This `Security` is a lightweight Data value object used for search results.
  # Inside provider classes that `include SecurityConcept`, unqualified `Security`
  # resolves to this Data class — NOT to `::Security` (the ActiveRecord model).
  Security = Data.define(:symbol, :name, :logo_url, :exchange_operating_mic, :country_code, :currency) do
    def initialize(symbol:, name:, logo_url:, exchange_operating_mic:, country_code:, currency: nil)
      super
    end
  end
  # `sector` and `industry` are free text by design. Provider taxonomies
  # disagree -- EODHD's `General.Sector` is not GICS, and no two agree on
  # wording -- so a constraint here would reject a value a provider
  # legitimately returns and break ingestion for that provider.
  #
  # Defaulted in an `initialize` override, the same way the `Security` above
  # defaults `currency:`. This Data has eleven implementers; without the
  # defaults every one of them would raise at construction the day these
  # fields were added.
  #
  # `constituents` is a fund's own holdings -- an array of
  # `{ticker:, name:, weight:}`, weight being the provider's percentage of fund
  # assets. Nil for anything that is not a fund, which is most securities, and
  # nil rather than `[]` so "not a fund" and "a fund we could not read" are the
  # same answer to the caller: neither is worth asking about again.
  SecurityInfo = Data.define(:symbol, :name, :links, :logo_url, :description, :kind, :exchange_operating_mic,
                             :sector, :industry, :constituents) do
    def initialize(symbol:, name:, links:, logo_url:, description:, kind:, exchange_operating_mic:,
                   sector: nil, industry: nil, constituents: nil)
      super
    end
  end
  Price = Data.define(:symbol, :date, :price, :currency, :exchange_operating_mic)

  def search_securities(symbol, country_code: nil, exchange_operating_mic: nil)
    raise NotImplementedError, "Subclasses must implement #search_securities"
  end

  def fetch_security_info(symbol:, exchange_operating_mic:)
    raise NotImplementedError, "Subclasses must implement #fetch_security_info"
  end

  def fetch_security_price(symbol:, exchange_operating_mic:, date:)
    raise NotImplementedError, "Subclasses must implement #fetch_security_price"
  end

  def fetch_security_prices(symbol:, exchange_operating_mic:, start_date:, end_date:)
    raise NotImplementedError, "Subclasses must implement #fetch_security_prices"
  end

  # Maximum number of calendar days of historical data the provider can return.
  # Callers should clamp start_date to avoid requesting data beyond this window.
  # Override in subclasses with provider-specific limits.
  def max_history_days
    nil # nil means no known limit
  end
end
