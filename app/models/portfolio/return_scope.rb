# What return method an account's data can actually support.
#
# Implements contract rows R15 and R16. This exists so the engine cannot quote a
# figure the underlying records do not justify: a manually valued account has no
# record of what was paid in, so a money-weighted return over its flows would be
# a fabrication, and an account with one day of history has no return at all.
#
# Deliberately evaluated BEFORE the metrics rather than filtered afterwards --
# a suppression rule applied at the view layer is one refactor away from being
# forgotten.
class Portfolio::ReturnScope
  # The account records buys, sells or transfers, so its external flows are
  # known and every method is available.
  TRADE_TRACKED = :trade_tracked

  # The account's value is asserted by valuations. Its change over time is a
  # value return; its flows are unknown, so no money-weighted return.
  VALUATION_TRACKED = :valuation_tracked

  # Fewer than two days of balance history in the period: no return exists.
  INSUFFICIENT = :insufficient

  KINDS = [ TRADE_TRACKED, VALUATION_TRACKED, INSUFFICIENT ].freeze

  attr_reader :account, :period

  def initialize(account:, period:)
    @account = account
    @period = period
  end

  def kind
    @kind ||= begin
      if balance_days < 2
        INSUFFICIENT
      elsif trades? || external_transactions?
        TRADE_TRACKED
      elsif valuations?
        VALUATION_TRACKED
      else
        # Balances exist but nothing explains them. Treated as valuation-tracked:
        # the value change is real and reportable, the flows are not known.
        VALUATION_TRACKED
      end
    end
  end

  def insufficient? = kind == INSUFFICIENT
  def trade_tracked? = kind == TRADE_TRACKED
  def valuation_tracked? = kind == VALUATION_TRACKED

  def supports_time_weighted_return?
    !insufficient?
  end

  # R16.
  def supports_money_weighted_return?
    trade_tracked?
  end

  # The i18n key suffix the UI uses to label the figure, so a valuation-tracked
  # account is never captioned "time-weighted return".
  def return_label_key
    valuation_tracked? ? "value_return" : "time_weighted_return"
  end

  # Balance rows in the account's currency inside the period. Public so a
  # caller weighing several accounts can tell one that holds nothing in the
  # period (no rows, nothing to withhold) from one with a single day (R15).
  def balance_days
    @balance_days ||= account.balances
      .where(currency: account.currency, date: period.date_range)
      .count
  end

  private
    # Every tracking check reads the same records: the account's live entries
    # up to the end of the period. Live means F9's rule, and `entries.excluded`
    # is nullable, so NULL counts as live through COALESCE. History before the
    # period counts, because flows known from earlier are still known inside
    # it.
    def live_entries_through_period_end
      account.entries
        .where("COALESCE(entries.excluded, false) = false")
        .where("entries.date <= ?", period.end_date)
    end

    def trades?
      return @trades if defined?(@trades)
      @trades = live_entries_through_period_end.where(entryable_type: "Trade").exists?
    end

    # A transfer in or out is as good as a trade for knowing the flows.
    #
    # One query through the classifier's SQL form rather than the Ruby form per
    # entry: the Ruby form looks up transfers and counterparts row by row, which
    # over an account's whole history is a round trip per transaction. The two
    # forms are held to agree by the classifier's parity test.
    def external_transactions?
      return @external_transactions if defined?(@external_transactions)

      aliases = {
        entries: "entries", trades: "flow_trades",
        transactions: "flow_transactions", counterpart: "flow_counterpart_entries"
      }
      sql = <<~SQL
        SELECT EXISTS (
          SELECT 1
          FROM entries
          #{Portfolio::FlowClassifier.sql_joins(**aliases)}
          WHERE entries.account_id = :account_id
            AND entries.entryable_type = 'Transaction'
            AND entries.date <= :end_date
            AND COALESCE(entries.excluded, false) = false
            AND #{Portfolio::FlowClassifier.sql_case(**aliases)} = 'external'
        )
      SQL

      value = ActiveRecord::Base.connection.select_value(
        ActiveRecord::Base.sanitize_sql_array([
          sql, { account_id: account.id, end_date: period.end_date, scope_account_ids: [ account.id ] }
        ])
      )
      @external_transactions = ActiveModel::Type::Boolean.new.cast(value) == true
    end

    def valuations?
      return @valuations if defined?(@valuations)
      @valuations = live_entries_through_period_end.where(entryable_type: "Valuation").exists?
    end
end
