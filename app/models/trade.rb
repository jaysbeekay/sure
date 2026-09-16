class Trade < ApplicationRecord
  include Entryable, Monetizable

  monetize :price
  monetize :fee

  belongs_to :security
  belongs_to :category, optional: true

  # Use the same activity labels as Transaction
  ACTIVITY_LABELS = Transaction::ACTIVITY_LABELS.dup.freeze

  # The labels that mean the asset went somewhere else you own rather than
  # being bought or sold.
  #
  # Deliberately NOT `Transaction::INTERNAL_MOVEMENT_LABELS`, which also holds
  # "Exchange". On cash that means a currency exchange and is internal; on a
  # security the label covers "currency **or security** exchanges"
  # (docs/onboarding/guide.md), and a security-for-security exchange can
  # dispose of an appreciated asset.
  #
  # The two errors are not symmetrical. Listing a movement that was not a sale
  # is visible and correctable; erasing a realized gain is neither — it simply
  # is not there. So only labels that unambiguously preserve ownership are
  # excluded, and an ambiguous one is left where the user can see it.
  INTERNAL_MOVEMENT_LABELS = %w[Transfer Sweep\ In Sweep\ Out].freeze

  # Moving an asset between places you own is not an acquisition, so it must not
  # set a cost basis. Named here because Holding reads it.
  #
  # A single label rather than INTERNAL_MOVEMENT_LABELS above, though both rest
  # on ownership being preserved: this one is the label the onchain processor
  # writes, and the only one seen setting a basis it should not. Widening the
  # basis guard to the sweep labels would change which holdings lose their
  # basis, and nothing has shown a sweep landing on a security — so it stays
  # narrow until something does.
  TRANSFER_LABEL = "Transfer".freeze

  validates :qty, presence: true
  validates :price, :currency, presence: true
  validates :investment_activity_label, inclusion: { in: ACTIVITY_LABELS }, allow_nil: true

  def exchange_rate
    extra&.dig("exchange_rate")
  end

  def exchange_rate=(value)
    if value.blank?
      self.extra = (extra || {}).merge("exchange_rate" => nil, "exchange_rate_invalid" => false)
    else
      begin
        normalized_value = Float(value)
        raise ArgumentError unless normalized_value.finite?

        self.extra = (extra || {}).merge("exchange_rate" => normalized_value, "exchange_rate_invalid" => false)
      rescue ArgumentError, TypeError
        self.extra = (extra || {}).merge("exchange_rate" => value, "exchange_rate_invalid" => true)
      end
    end
  end

  validate :exchange_rate_must_be_valid

  # Trade types for categorization
  def buy?
    qty.positive?
  end

  def sell?
    qty.negative?
  end

  # A negative quantity that left for another account you own. It looks exactly
  # like a sale — same sign, same shape — and only the label tells them apart.
  def internal_movement?
    INTERNAL_MOVEMENT_LABELS.include?(investment_activity_label)
  end

  class << self
    def build_name(type, qty, ticker)
      prefix = type == "buy" ? "Buy" : "Sell"
      "#{prefix} #{qty.to_d.abs} shares of #{ticker}"
    end
  end

  def unrealized_gain_loss
    return nil unless qty.positive?
    current_price = security.current_price
    return nil if current_price.nil?

    current_value = current_price * qty.abs
    cost_basis = price_money * qty.abs

    Trend.new(current: current_value, previous: cost_basis)
  end

  # Set by callers that list many sell trades, so calculate_realized_gain_loss
  # reads one preloaded set per account instead of querying holdings per trade.
  # An empty array is authoritative (see the `defined?` check below): it means
  # "preloaded, and there are none", not "not preloaded".
  #
  # Clearing the memo is the point of writing this out rather than using
  # attr_writer: realized_gain_loss caches on first call, so a trade measured
  # before its holdings arrived would keep returning the figure it derived
  # without them. Callers are meant to preload first, but a public writer that
  # silently ignores a later assignment is a trap.
  def preloaded_holdings=(value)
    @preloaded_holdings = value
    remove_instance_variable(:@realized_gain_loss) if defined?(@realized_gain_loss)
  end

  # Set by callers that list many disposals, so the proceeds conversion below
  # reads one preloaded set instead of a query per foreign disposal. Keyed
  # `[from, to, date]`.
  #
  # NOT authoritative when a key is absent, unlike preloaded_holdings: the
  # preload keys the basis side on the ACCOUNT's currency, which is what the
  # sync and import paths write a holding in, and a holding carried in some
  # other currency would miss the preload. Treating that as "no rate" would
  # exclude a disposal that is perfectly measurable, so a miss falls back to
  # the single lookup rather than to a wrong answer.
  def preloaded_exchange_rates=(value)
    @preloaded_exchange_rates = value
    remove_instance_variable(:@realized_gain_loss) if defined?(@realized_gain_loss)
  end

  # One query for every rate a set of disposals can need, instead of one per
  # disposal. The date set and the currency sets are each small; the product is
  # a superset of the pairs actually wanted, which is cheaper to fetch than to
  # describe pair by pair in SQL.
  def self.preload_exchange_rates(trades)
    return if trades.empty?

    wanted = trades.filter_map do |trade|
      from = trade.currency
      to = trade.entry.account.currency
      next if from.blank? || to.blank? || from == to

      [ from, to, trade.entry.date ]
    end

    if wanted.empty?
      trades.each { |trade| trade.preloaded_exchange_rates = {} }
      return
    end

    rates = ExchangeRate
      .where(
        from_currency: wanted.map(&:first).uniq,
        to_currency: wanted.map(&:second).uniq,
        date: wanted.map(&:third).uniq
      )
      .to_h { |rate| [ [ rate.from_currency, rate.to_currency, rate.date ], rate.rate ] }

    trades.each { |trade| trade.preloaded_exchange_rates = rates }
  end

  # Why #realized_gain_loss has no figure to give: `:missing_cost_basis` when
  # no holding at or before the disposal carries one, `:missing_exchange_rate`
  # when the proceeds cannot be expressed in the basis's currency on the
  # disposal's own date. nil when a figure was produced, and nil for a trade
  # that realises nothing -- a buy, or a position moved between accounts you
  # own, has no missing fact to report.
  #
  # A caller that lists disposals it could not measure needs to name WHICH fact
  # it lacks: telling a user their cost basis is unknown when the truth is a
  # missing rate sends them to fix the wrong thing.
  def realized_gain_loss_unavailable_reason
    realized_gain_loss
    @realized_gain_loss_unavailable_reason
  end

  # Calculates realized gain/loss for sell trades based on avg_cost at time of sale
  # Returns nil for buy trades or when cost basis cannot be determined
  def realized_gain_loss
    return @realized_gain_loss if defined?(@realized_gain_loss)

    @realized_gain_loss = calculate_realized_gain_loss
  end

  # Trades are always excluded from expense budgets
  # They represent portfolio management, not living expenses
  def excluded_from_budget?
    true
  end

  private

    def exchange_rate_must_be_valid
      if extra&.dig("exchange_rate_invalid")
        errors.add(:exchange_rate, "must be a number")
      elsif exchange_rate.present?
        numeric_rate = Float(exchange_rate) rescue nil
        if numeric_rate.nil? || !numeric_rate.finite? || numeric_rate <= 0
          errors.add(:exchange_rate, "must be greater than 0")
        end
      end
    end

    def calculate_realized_gain_loss
      @realized_gain_loss_unavailable_reason = nil

      return nil unless sell?
      # Moving an asset to another account you own realises nothing. Without
      # this the cost basis is compared against the day's price and the
      # difference is booked as a gain the user never made.
      return nil if internal_movement?

      # Use preloaded holdings if available (set by reports controller to avoid N+1)
      # Treat defined-but-empty preload as authoritative to prevent DB fallback
      holding = if defined?(@preloaded_holdings)
        # Use select + max_by for deterministic selection regardless of array order
        (@preloaded_holdings || [])
          .select { |h| h.security_id == security_id && h.date <= entry.date }
          .max_by(&:date)
      else
        # Fall back to database query only when not preloaded
        entry.account.holdings
          .where(security_id: security_id)
          .where("date <= ?", entry.date)
          .order(date: :desc)
          .first
      end

      unless holding&.avg_cost
        @realized_gain_loss_unavailable_reason = :missing_cost_basis
        return nil
      end

      cost_basis = holding.avg_cost * qty.abs
      sale_proceeds = converted_to_basis_currency(price_money * qty.abs, cost_basis.currency)

      if sale_proceeds.nil?
        @realized_gain_loss_unavailable_reason = :missing_exchange_rate
        return nil
      end

      Trend.new(current: sale_proceeds, previous: cost_basis)
    end

    # The proceeds are priced in the security's currency; the basis is carried
    # in the one the position is held in. `Trend#value` is `current - previous`
    # and `Money#-` keeps the left operand's currency while taking the right
    # one's bare amount, so without this the two were subtracted as plain
    # numbers and the difference was then labelled with the disposal's
    # currency -- an error that scaled with the rate and changed sign either
    # side of parity.
    #
    # Converted in THIS direction, and not the other, because it is the
    # direction the data holds: MarketDataImporter's first required pair is
    # every entry currency against its account's, so a EUR disposal in a USD
    # account has a EUR->USD row for the day it happened, while USD->EUR is
    # only ever there by accident of another account.
    #
    # Exact date, exact direction, no parity fallback and no nearest-rate
    # lookback. A disposal happened on one known day; the rate for that day is
    # the rate, and its absence is a fact to report rather than a 1.0 nobody
    # can see.
    def converted_to_basis_currency(proceeds, basis_currency)
      from = proceeds.currency.iso_code
      to = basis_currency.iso_code
      return proceeds if from == to

      rate = preloaded_rate(from, to) ||
             ExchangeRate.find_by(from_currency: from, to_currency: to, date: entry.date)&.rate
      return nil if rate.nil?

      Money.new(proceeds.amount * rate, to)
    end

    def preloaded_rate(from, to)
      return nil unless defined?(@preloaded_exchange_rates)

      (@preloaded_exchange_rates || {})[[ from, to, entry.date ]]
    end
end
