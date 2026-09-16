# Realised profit and loss over time: what the portfolio actually banked, and
# in which month it banked it.
#
# This is deliberately NOT a return figure and carries no row in the returns
# contract. A return answers "how did the money perform"; this answers "what
# was crystallised, and when". They are different questions and the contract's
# gates are not the right ones to hold this to.
#
# FOUR THINGS ARE EASY TO GET WRONG HERE.
#
# 1. A transfer out looks exactly like a sale. Both carry a negative `qty`, so
#    a bare `qty < 0` filter books the full market value of every asset a user
#    moved between their own accounts as a realised gain. Trade::
#    INTERNAL_MOVEMENT_LABELS is the list of labels that mean ownership was
#    preserved, and it is deliberately narrower than Transaction's (see the
#    comment on that constant: "Exchange" on a security can genuinely dispose
#    of an appreciated asset, so it is left in).
#
# 2. A realised gain is locked at the moment of sale, so it converts at THAT
#    day's exchange rate, never today's. Marking a two-year-old disposal to
#    today's rate restates a number the user already has on a tax document.
#
# 3. A missing rate is not a rate of 1. The readiness review for #121 settled
#    this for the whole engine: no parity fallback. That rules out the obvious
#    helper -- ExchangeRate.rates_for ends in `rate&.rate || 1`, so it hands
#    back parity for a pair it could not find and the caller cannot tell the
#    two apart. Rates are read directly here, and a trade this class cannot
#    convert is reported in #excluded_trades rather than counted at par.
#
# 4. A trade whose cost basis cannot be determined is not a zero gain.
#    ReportsController#build_investment_metrics folds those to 0
#    (`gain ? ... : 0`), which silently drags a total toward zero with no
#    signal that anything is missing. They are excluded and counted here, the
#    same way 2.3 treats a holding with no cost basis.
class Portfolio::RealizedGains
  # One calendar month of realised activity.
  #
  # `losses` is a positive magnitude, as Portfolio::Drivers#fees is, so the two
  # series chart directly and the sign convention lives in exactly one place.
  Bucket = Data.define(:month, :gains, :losses, :trade_count) do
    def net
      gains - losses
    end
  end

  # Why a sell trade could not be measured. Each is reported rather than folded
  # into the figures -- see notes 3 and 4 above. The order is the order the
  # partial lists them in, and #excluded_trades filters the tally through this
  # list, so a reason missing from it is silently dropped from the UI.
  EXCLUSION_REASONS = %i[missing_cost_basis missing_exchange_rate].freeze

  attr_reader :accounts, :period, :currency, :active_until_dates

  # `accounts` is the same historical scope the returns are measured over, so
  # a realised-P&L timeline cannot quietly cover a different set of accounts
  # from the return figure printed beside it.
  #
  # `active_until_dates` is `{account_id => last_active_date}` for disabled
  # accounts, the same shape and the same source Portfolio::DailyReturns takes.
  def initialize(accounts:, period:, currency:, active_until_dates: {})
    @accounts = Array(accounts)
    @period = period
    @currency = currency
    @active_until_dates = (active_until_dates || {}).compact
  end

  # Months with realised activity, oldest first. A month with no disposals is
  # absent rather than present as a zero: an empty bar and a break-even month
  # are different facts.
  def buckets
    @buckets ||= measured_rows
      .group_by { |row| row[:date].beginning_of_month }
      .sort_by(&:first)
      .map { |month, rows| build_bucket(month, rows) }
  end

  def total_gains
    @total_gains ||= buckets.sum(BigDecimal(0), &:gains)
  end

  def total_losses
    @total_losses ||= buckets.sum(BigDecimal(0), &:losses)
  end

  def net
    total_gains - total_losses
  end

  def trade_count
    @trade_count ||= buckets.sum(0, &:trade_count)
  end

  # { missing_cost_basis: n, missing_exchange_rate: n }, omitting reasons with
  # no trades. The section surfaces this so a total that leaves trades out says
  # so on the page rather than only in this object.
  def excluded_trades
    @excluded_trades ||= begin
      counts = exclusions.tally
      EXCLUSION_REASONS.filter_map { |reason| [ reason, counts[reason] ] if counts[reason] }.to_h
    end
  end

  def excluded_trade_count
    @excluded_trade_count ||= exclusions.size
  end

  # Excluded disposals count. A period whose every disposal was unmeasurable
  # has no buckets, and gating the section on buckets alone hid the one thing
  # the user needed to see: that the page is missing data. Reporting exclusions
  # and then hiding the report was the opposite of the intent in note 4.
  def any?
    buckets.any? || excluded_trade_count.positive?
  end

  private
    def build_bucket(month, rows)
      Bucket.new(
        month: month,
        gains: rows.sum(BigDecimal(0)) { |row| row[:amount].positive? ? row[:amount] : BigDecimal(0) },
        losses: rows.sum(BigDecimal(0)) { |row| row[:amount].negative? ? -row[:amount] : BigDecimal(0) },
        trade_count: rows.size
      )
    end

    # Each measurable disposal as { date:, amount: } in family currency.
    # Computed once, because it also decides what lands in #exclusions.
    def measured_rows
      measure!
      @measured_rows
    end

    def exclusions
      measure!
      @exclusions
    end

    def measure!
      return if defined?(@measured_rows)

      @measured_rows = []
      @exclusions = []

      sell_trades.each do |trade|
        gain = trade.realized_gain_loss

        # nil is one of two facts the trade could not establish -- no cost
        # basis, or no rate to express the proceeds in the basis's currency on
        # the day of the disposal. Trade names which, and the two send a user
        # to different places, so the tally keeps them apart. Neither is a zero
        # gain.
        if gain.nil?
          next @exclusions << (trade.realized_gain_loss_unavailable_reason || :missing_cost_basis)
        end

        # The figure arrives in the currency the position is held in, which is
        # not necessarily the disposal's (jaysbeekay/sure#169) and not
        # necessarily this statement's. Convert from the currency it actually
        # carries, at the trade's own date.
        amount = converted(gain.value, gain.value.currency.iso_code, trade.entry.date)
        next @exclusions << :missing_exchange_rate if amount.nil?

        @measured_rows << { date: trade.entry.date, amount: amount }
      end
    end

    def sell_trades
      @sell_trades ||= begin
        trades = load_sell_trades
        preload_holdings(trades)
        trades
      end
    end

    def load_sell_trades
      return [] if account_ids.empty?

      Trade
        .joins(entry: :account)
        .where(entries: { account_id: account_ids, date: period.date_range })
        .where("trades.qty < 0")
        # Note 1: ownership was preserved, so nothing was realised. Filtered in
        # SQL so these are never loaded; Trade#realized_gain_loss independently
        # returns nil for them, and neither check is load-bearing alone.
        .where(
          "trades.investment_activity_label IS NULL OR trades.investment_activity_label NOT IN (?)",
          Trade::INTERNAL_MOVEMENT_LABELS
        )
        .includes(entry: :account)
        .to_a
        .reject { |trade| after_cutoff?(trade) }
    end

    # A disabled account stops contributing on its cut-off date, exactly as it
    # stops contributing to the value chart and to the daily returns.
    def after_cutoff?(trade)
      cutoff = active_until_dates[trade.entry.account_id]
      cutoff.present? && trade.entry.date > cutoff
    end

    # Two queries for every account involved, handed to each trade, so
    # Trade#realized_gain_loss never falls back to its own lookups.
    #
    # The holdings query alone is not enough. A holding with no stored
    # cost_basis -- the common provider-synced case -- sends Holding#avg_cost
    # into #calculate_avg_cost, which asks three more questions per holding.
    # Measured over distinct securities that is 9 queries for 2 disposals and
    # 21 for 6. Holding.preload_avg_costs answers all of them in the one
    # grouped query P40 was written for, so the count stays flat.
    #
    # Scoped to the securities actually sold: loading every daily snapshot of
    # every security the account has ever held, to read the few that were
    # disposed of, is work the period does not need.
    def preload_holdings(trades)
      return if trades.empty?

      ids = trades.map { |trade| trade.entry.account_id }.uniq
      holdings = Holding
        .where(account_id: ids, security_id: trades.map(&:security_id).uniq)
        .where("date <= ?", period.date_range.end)
        .order(date: :desc)
        .to_a

      Holding.preload_avg_costs(holdings)
      by_account = holdings.group_by(&:account_id)

      trades.each do |trade|
        trade.preloaded_holdings = by_account[trade.entry.account_id] || []
      end
    end

    # Note 2: each disposal at its own trade date. Note 3: nil, never 1, when
    # the rate for that date is not held.
    def converted(amount, from, date)
      numeric = amount.is_a?(Money) ? amount.amount : amount
      return numeric if from.blank? || from == currency

      rate = rates_by_date.dig(date, from)
      return nil if rate.nil?

      numeric * rate
    end

    # { date => { from_currency => rate } }, in one query.
    #
    # DELIBERATELY NOT ExchangeRate.rates_for, though it is the batch helper
    # that exists for this. Its last line is `result[currency] = rate&.rate
    # || 1`: a pair it cannot find is returned at parity with a log line, so a
    # caller cannot tell "one to one" from "no idea". Portfolio::DailyReturns
    # refuses the same fallback for the same reason and raises `rate_missing`
    # instead ("a row with no rate is flagged, never converted at parity").
    #
    # Exact date only, and no nearest-rate lookback either: a disposal happened
    # on one known day, so the rate for that day is the rate, and its absence
    # is a fact worth reporting rather than papering over with a neighbouring
    # day's.
    def rates_by_date
      return @rates_by_date if defined?(@rates_by_date)

      # Both sets: a disposal is converted from the currency its POSITION is
      # held in (Trade#realized_gain_loss converts the proceeds into the basis's
      # currency first), and the account's currency is where that comes from.
      # The trades' own currencies stay in the list because a holding written in
      # the security's currency carries a gain in it.
      foreign = (
        sell_trades.filter_map(&:currency) +
        sell_trades.filter_map { |trade| trade.entry.account.currency }
      ).uniq - [ currency ]
      dates = sell_trades.map { |trade| trade.entry.date }.uniq

      @rates_by_date =
        if foreign.empty? || dates.empty?
          {}
        else
          ExchangeRate
            .where(from_currency: foreign, to_currency: currency, date: dates)
            .group_by(&:date)
            .transform_values { |rates| rates.to_h { |rate| [ rate.from_currency, rate.rate ] } }
        end
    end

    def account_ids
      @account_ids ||= accounts.map(&:id)
    end
end
