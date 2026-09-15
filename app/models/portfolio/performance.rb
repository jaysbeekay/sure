# The performance metric surface for a set of accounts over a period.
#
# Implements contract rows R3, R4, R5, R8, R14, R15 (applied to the whole scope)
# and R17. A value object in the shape of Loan::SimulationResult: constructed
# with its boundaries, computes once, answers questions.
#
# CACHING (R14). The key comes from Family#build_cache_key with
# `invalidate_on_data_updates: true`, which folds in `latest_sync_completed_at`.
# `entries_cache_version` -- the key the rest of InvestmentStatement uses -- is
# NOT sufficient here: it is `entries.count` plus `entries.maximum(:updated_at)`,
# and a daily price sync changes holdings and therefore balances while touching
# no entry at all. Returns cached on it would stay stale until the user next
# edited a transaction.
class Portfolio::Performance
  # Bumped when the meaning of a cached figure changes, so warm caches stop
  # serving the old interpretation (the pattern upstream #3350 used for
  # totals_query/v2).
  #
  # v2: the money-weighted return is withheld when any contributing account
  # cannot support one (R16), and flows follow the rate and cut-off rules.
  #
  # v3: an account entering or leaving the scope is a composition flow rather
  # than a return (R17), and an account with a single balance day withholds the
  # time-weighted figures (R15).
  CACHE_VERSION = "v3".freeze

  # R5: the balance rows are calendar daily, so the series includes weekends and
  # holidays as structural zeros. Annualising that by the trading-day convention
  # (252) would overstate the result; the calendar year is the honest divisor
  # for a calendar-daily series.
  TRADING_PERIODS_PER_YEAR = 365

  # Calendar days per year, for turning a day count into a year fraction. The
  # same number as TRADING_PERIODS_PER_YEAR today and deliberately a separate
  # constant: that one counts return OBSERVATIONS, to scale a standard
  # deviation, and this one counts DAYS. Move the series to weekly balances and
  # the first becomes 52 while this must stay 365, so binding them together
  # would quietly corrupt annualisation the day the interval changed.
  DAYS_PER_YEAR = 365.0

  # R4: annualising anything shorter produces a number nobody should be shown.
  MIN_DAYS_FOR_ANNUALISATION = 365

  attr_reader :family, :account_ids, :period, :user, :active_until_dates, :scope_account_ids

  def initialize(family:, account_ids:, period:, user: nil, active_until_dates: {}, scope_account_ids: nil)
    @family = family
    @account_ids = Array(account_ids).compact.map(&:to_s)
    @period = period
    @user = user
    @active_until_dates = active_until_dates || {}
    @scope_account_ids = scope_account_ids
  end

  # R3. Chained daily returns, as a BigDecimal fraction (0.21 == 21%).
  # nil when there is nothing to report or a rate is missing (R13).
  def time_weighted_return
    metrics[:twr]
  end
  alias_method :twr, :time_weighted_return

  # R4. nil below MIN_DAYS_FOR_ANNUALISATION.
  def annualized_time_weighted_return
    metrics[:annualized_twr]
  end
  alias_method :annualized_twr, :annualized_time_weighted_return

  # R8. nil when the scope cannot support it, or XIRR could not solve.
  def money_weighted_return
    metrics[:mwr]
  end
  alias_method :mwr, :money_weighted_return

  # R5. Annualised standard deviation of daily returns.
  def volatility
    metrics[:volatility]
  end

  # Largest peak-to-trough fall of the chained index, as a positive fraction.
  def max_drawdown
    metrics[:max_drawdown]
  end

  # [[date, index], ...] rebased on a base of 100, where the FIRST point is the
  # level after the first return (100 * (1 + r1)), not the base itself. This is the
  # flow-adjusted series a chart plots: it removes the effect of deposits, so it
  # can be laid beside a benchmark (#124) without the shapes disagreeing purely
  # because money went in.
  def index_series
    metrics[:index_series]
  end

  def drivers
    metrics[:drivers]
  end

  # R13. True when a currency pair had no rate anywhere in the period, in which
  # case every return figure is nil and the UI must say why rather than showing
  # a parity-converted number.
  def rate_missing?
    metrics[:rate_missing]
  end

  # R6. Days whose denominator was zero or negative.
  def suppressed_dates
    metrics[:suppressed_dates]
  end

  def any?
    account_ids.any? && metrics[:day_count] > 0
  end

  # Exposed for tests and for callers that want the raw series.
  def daily_returns
    @daily_returns ||= Portfolio::DailyReturns.new(
      account_ids: account_ids,
      currency: family.currency,
      period: period,
      active_until_dates: active_until_dates,
      scope_account_ids: scope_account_ids
    )
  end

  # Every constructor argument that can change a figure has to be in here.
  # `active_until_dates` and `scope_account_ids` are easy to forget because
  # neither is passed today, but both change the underlying rows materially --
  # a cut-off date drops an account's later history entirely -- so omitting them
  # would let the first caller to use them read another caller's cached answer.
  #
  # Both the flow scope and the cut-off dates are keyed as DailyReturns resolves
  # them, not as they were passed. For the scope: an omitted one means "the
  # accounts themselves" while an explicit `[]` means "nothing is inside", and
  # those classify transfers differently. For the cut-offs: DailyReturns
  # compacts them and normalises each value to an ISO8601 string, so
  # `{ id => nil }` is valid input meaning "no cut-off" and has to key
  # identically to an omitted hash -- which it does only after that compaction,
  # and a key-type difference would key two identical scopes differently.
  #
  # Nothing is converted here for the same reason: the resolved values are
  # already the strings DailyReturns keyed its own query on, so a `to_date`
  # round trip would only re-parse them.
  #
  # The digest only shortens the key; nothing depends on it being secret.
  # SHA-256 rather than MD5 so code scanning does not flag account ids fed to a
  # broken hash.
  def cache_key
    family.build_cache_key(
      [
        "portfolio_performance", CACHE_VERSION, user&.id,
        Digest::SHA256.hexdigest(
          [
            account_ids.sort.join(","),
            "scope:" + daily_returns.scope_account_ids.sort.join(","),
            daily_returns.active_until_dates.map { |id, date| "#{id}:#{date}" }.sort.join(",")
          ].join("|")
        ),
        period.start_date, period.end_date
      ].compact.join("_"),
      invalidate_on_data_updates: true
    )
  end

  private
    def metrics
      @metrics ||= Rails.cache.fetch(cache_key) { compute }
    end

    def compute
      rows = daily_returns.rows
      returns = daily_returns.returns
      rate_missing = daily_returns.rate_missing?

      drivers = Portfolio::Drivers.new(daily_returns)

      # R13: a missing rate makes every ratio unsafe, so the figures are
      # withheld. The drivers are still reported -- they are money, and the
      # caller can see which part is unexplained -- but nothing is expressed as
      # a percentage of a value we could not convert.
      #
      # R15 applied to the whole scope: an account with a single day of balance
      # history supports no return, so it withholds every time-weighted figure.
      withhold_time_weighted = rate_missing || !time_weighted_supported?
      chained = withhold_time_weighted ? nil : chain(returns)

      {
        twr: chained,
        annualized_twr: annualize(chained),
        mwr: rate_missing || !money_weighted_supported?(rows) ? nil : money_weighted(rows),
        volatility: withhold_time_weighted ? nil : annualized_volatility(returns),
        max_drawdown: withhold_time_weighted ? nil : drawdown(returns),
        index_series: withhold_time_weighted ? [] : rebased_index(returns),
        drivers: drivers.to_h,
        rate_missing: rate_missing,
        suppressed_dates: rows.select(&:suppressed).map(&:date),
        day_count: rows.size
      }
    end

    # R3.
    def chain(returns)
      return nil if returns.empty?

      returns.reduce(BigDecimal(1)) { |acc, (_date, r)| acc * (1 + r) } - 1
    end

    # R4.
    def annualize(chained)
      return nil if chained.nil?
      return nil if period.days < MIN_DAYS_FOR_ANNUALISATION

      years = period.days / DAYS_PER_YEAR
      growth = (1 + chained).to_f
      # A total loss leaves nothing to annualise; the root of a negative is not
      # a return.
      return nil if growth <= 0

      BigDecimal(((growth**(1.0 / years)) - 1).to_s)
    end

    # R15 and R16 applied to the whole scope. A money-weighted return over
    # several accounts is only as good as the flows of every account in it:
    # a valuation-tracked account's flows are unknown, and an account with one
    # day of history has no opening position to measure from, so either one
    # withholds the figure. An account with no balance rows in the period
    # contributes nothing and does not block it, the same rule R13 applies to
    # rates. A period of fewer than two days has no duration to annualise.
    def money_weighted_supported?(rows)
      return false if rows.size < 2

      Account.where(id: account_ids).to_a.all? do |account|
        scope = Portfolio::ReturnScope.new(account: account, period: period)
        scope.balance_days.zero? || scope.supports_money_weighted_return?
      end
    end

    # R15 applied to the whole scope for the time-weighted figures, mirroring
    # #money_weighted_supported?: an account with exactly one day of balance
    # history has no return to contribute, so it withholds the aggregate. An
    # account with no balance rows in the period contributes nothing and does
    # not block it.
    def time_weighted_supported?
      Account.where(id: account_ids).to_a.none? do |account|
        Portfolio::ReturnScope.new(account: account, period: period).balance_days == 1
      end
    end

    # R8 and R17. The opening value is the investor's first outlay; every flow
    # follows -- external flows, and the value an account brought into or carried
    # out of the scope -- and the closing value is what they could walk away with.
    def money_weighted(rows)
      return nil if rows.empty?

      opening = rows.first.value_open
      closing = rows.last.value_close

      flows = []
      flows << Portfolio::Xirr::Flow.new(date: rows.first.date, amount: -opening) unless opening.zero?

      rows.each do |row|
        flow = row.external_flow + row.composition_flow
        next if flow.zero?
        flows << Portfolio::Xirr::Flow.new(date: row.date, amount: -flow)
      end

      flows << Portfolio::Xirr::Flow.new(date: rows.last.date, amount: closing) unless closing.zero?

      Portfolio::Xirr.rate_or_nil(flows)
    end

    # R5.
    def annualized_volatility(returns)
      values = returns.map { |(_date, r)| r.to_f }
      return nil if values.size < 2

      mean = values.sum / values.size
      variance = values.sum { |v| (v - mean)**2 } / (values.size - 1)
      return nil if variance.negative?

      BigDecimal((Math.sqrt(variance) * Math.sqrt(TRADING_PERIODS_PER_YEAR)).to_s)
    end

    def drawdown(returns)
      return nil if returns.empty?

      peak = BigDecimal(1)
      level = BigDecimal(1)
      worst = BigDecimal(0)

      returns.each do |(_date, r)|
        level *= (1 + r)
        peak = level if level > peak
        next unless peak.positive?

        fall = (peak - level) / peak
        worst = fall if fall > worst
      end

      worst
    end

    def rebased_index(returns)
      level = BigDecimal(100)

      returns.map do |(date, r)|
        level *= (1 + r)
        [ date, level ]
      end
    end
end
