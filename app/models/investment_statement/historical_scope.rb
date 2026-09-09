# The account scope behind InvestmentStatement's chart series.
#
# Unlike InvestmentStatement#investment_accounts (visible accounts only), this
# scope is *historical*: it also includes disabled accounts, exactly the way
# net worth is charted (see BalanceSheet::HistoricalAccountScope). Closing a
# broker must not retroactively erase its history from the portfolio chart --
# the value the user held last March is still the value they held last March.
#
# The trade-off is a documented divergence: the last point of a series is the
# *historical* portfolio value, while InvestmentStatement#portfolio_value is
# the *live* one. They coincide unless a disabled account's last balance is
# non-zero, in which case the series' final point includes that residual
# balance (up to the account's cut-off date) and portfolio_value does not.
class InvestmentStatement::HistoricalScope
  INVESTMENT_ACCOUNTABLE_TYPES = %w[Investment Crypto].freeze

  def initialize(family, user: nil)
    @family = family
    @user = user
  end

  def accounts
    @accounts ||= BalanceSheet::HistoricalAccountScope
      .new(family, user: user)
      .relation
      .where(accountable_type: INVESTMENT_ACCOUNTABLE_TYPES)
      .to_a
  end

  def account_ids
    @account_ids ||= accounts.map(&:id)
  end

  # The last date each disabled account still contributes to a series. Mirrors
  # BalanceSheet::NetWorthSeriesBuilder#disabled_account_active_until_dates so
  # a closed broker drops out of the chart on the day it was disabled rather
  # than carrying its final balance forward forever.
  def active_until_dates
    @active_until_dates ||= accounts.each_with_object({}) do |account, dates|
      next unless account.disabled?

      disabled_on = (account.disabled_at || account.updated_at).to_date
      dates[account.id] = disabled_on - 1.day
    end
  end

  private
    attr_reader :family, :user
end
