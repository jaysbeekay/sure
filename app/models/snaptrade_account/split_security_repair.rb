# Repairs one account's SnapTrade positions whose holdings and trades sit on
# different Security rows of the same ticker.
#
# Before jaysbeekay/sure#334, resolve_security looked a ticker up with no
# exchange and no ORDER BY, so a position's holdings and trades could land on
# different rows. Every cost-basis reader filters on security_id, so such a
# holding shows "No cost basis". The deterministic lookup keeps a position on
# the row it already holds, which keeps an existing split in place rather than
# healing it.
#
# The repair moves this account's rows only. It never destroys a Security,
# never moves a Security::Price (prices are shared by every family holding the
# security), and leaves other providers' holdings and other accounts alone.
# The target is the row held_security_for returns -- the one the next sync
# resolves to -- so the repaired position stays put.
#
# A dry run (the default) reports what it would do and writes nothing.
class SnaptradeAccount::SplitSecurityRepair
  include SnaptradeAccount::DataHelpers

  Result = Data.define(
    :account, :ticker, :target_id, :target_source, :source_ids,
    :trades_moved, :holdings_moved, :holdings_dropped, :price_gap_dates
  )

  def self.accounts
    Account.where(id: AccountProvider.where(provider_type: "SnaptradeAccount").select(:account_id))
  end

  def initialize(account, dry_run: true)
    @account = account
    @dry_run = dry_run
  end

  def dry_run?
    @dry_run
  end

  def run
    return [] unless snaptrade_provider_id

    plans = split_tickers.filter_map { |ticker, security_ids| plan_for(ticker, security_ids) }
    return [] if plans.empty?

    return plans.map { |plan| plan[:result] } if dry_run?

    ActiveRecord::Base.transaction do
      plans.each { |plan| apply(plan) }
      Balance::Materializer.new(
        account, strategy: :reverse, security_ids: plans.map { |plan| plan[:result].target_id }
      ).materialize_balances
    end

    plans.map { |plan| plan[:result] }
  end

  private
    attr_reader :account

    def snaptrade_provider_id
      @snaptrade_provider_id ||= account.account_providers.find_by(provider_type: "SnaptradeAccount")&.id
    end

    # SnapTrade's own holdings and those with no provider (materialized from
    # the account's trades). Another provider's holding is that provider's.
    def repairable_holdings
      account.holdings.where(account_provider_id: [ snaptrade_provider_id, nil ])
    end

    # { "TICKER" => [security_id, ...] } for tickers spread over more than one row.
    def split_tickers
      security_ids = (account.trades.distinct.pluck(:security_id) + repairable_holdings.distinct.pluck(:security_id)).uniq

      Security.where(id: security_ids)
        .pluck(:id, :ticker)
        .group_by { |_id, ticker| ticker.to_s.upcase.strip }
        .transform_values { |rows| rows.map(&:first).sort }
        .select { |ticker, ids| ticker.present? && ids.size > 1 }
        .sort.to_h
    end

    def plan_for(ticker, security_ids)
      target_id, target_source = target_for(ticker, security_ids)
      source_ids = security_ids - [ target_id ]
      return nil if source_ids.empty?

      trades = account.trades.where(security_id: source_ids)
      moves, drops = holding_moves(target_id, source_ids)

      {
        trades: trades,
        moves: moves,
        drops: drops,
        result: Result.new(
          account: account,
          ticker: ticker,
          target_id: target_id,
          target_source: target_source,
          source_ids: source_ids,
          trades_moved: trades.count,
          holdings_moved: moves.size,
          holdings_dropped: drops.size,
          price_gap_dates: price_gap_dates(target_id, source_ids)
        )
      }
    end

    # The row the next sync resolves to, or, with no holding to name one, the
    # row with the most trades.
    def target_for(ticker, security_ids)
      held = held_security_for(account, ticker)
      return [ held.id, :held ] if held

      counts = account.trades.where(security_id: security_ids).group(:security_id).count
      [ security_ids.max_by { |id| [ counts.fetch(id, 0), -security_ids.index(id) ] }, :most_trades ]
    end

    # Holdings are derived rows; the target keeps whatever it already has on a
    # date and currency, and the other row's holding there is dropped rather
    # than summed into it. Provider rows go first, so where two non-target rows
    # share a date the provider's snapshot is the one kept.
    def holding_moves(target_id, source_ids)
      taken = account.holdings.where(security_id: target_id).pluck(:date, :currency).to_set
      moves = []
      drops = []

      repairable_holdings.where(security_id: source_ids)
        .order(:date, Arel.sql("account_provider_id IS NULL"), :id)
        .each do |holding|
          key = [ holding.date, holding.currency ]
          if taken.include?(key)
            drops << holding.id
          else
            taken << key
            moves << holding.id
          end
        end

      [ moves, drops ]
    end

    # Dates in the account's history with a price on another row and none on
    # the target. Prices are not moved, so these days can go unpriced in the
    # moved history until market data fills the target.
    def price_gap_dates(target_id, source_ids)
      dates = account.start_date..Date.current
      target_dates = Security::Price.where(security_id: target_id, date: dates).distinct.pluck(:date)

      (Security::Price.where(security_id: source_ids, date: dates).distinct.pluck(:date) - target_dates).sort
    end

    def apply(plan)
      target_id = plan[:result].target_id

      Holding.where(id: plan[:drops]).delete_all if plan[:drops].any?
      Holding.where(id: plan[:moves]).update_all(security_id: target_id, updated_at: Time.current) if plan[:moves].any?
      plan[:trades].update_all(security_id: target_id)
    end
end
