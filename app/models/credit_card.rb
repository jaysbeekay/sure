class CreditCard < ApplicationRecord
  include Accountable

  DEFAULT_SUBTYPE = "credit_card"

  SUBTYPES = {
    "credit_card" => { short: "Credit Card", long: "Credit Card" }
  }.freeze

  StatementSummary = Data.define(
    :balance, :remaining, :charges, :credits, :payments_applied, :accrued, :adjustments,
    :due_date, :last_due_date, :next_close, :status, :scheduled_payment,
    :estimated_interest, :monthly_rate
  )
  ScheduledPayment = Data.define(:payment, :due_date)

  # The days in the year each interest basis divides the APR by to get the
  # daily periodic rate.
  DAY_COUNT_BASES = { "actual_365" => 365, "actual_360" => 360 }.freeze

  validates :day_count_convention, inclusion: { in: DAY_COUNT_BASES.keys }

  validates :statement_close_day, :due_day,
            numericality: { only_integer: true, greater_than_or_equal_to: 1, less_than_or_equal_to: 31 },
            allow_nil: true

  class << self
    def color
      "#F13636"
    end

    def icon
      "credit-card"
    end

    def classification
      "liability"
    end

    # The outstanding debt on a card whose provider reports the remaining
    # available credit instead of the balance owed. nil when there is no
    # positive limit, because the debt is then unknown. An overpaid card
    # reports more than its limit: clamp_overpayment turns that into zero
    # debt, otherwise it stays a negative (credit) balance.
    def debt_from_available_credit(credit_limit:, available_credit:, clamp_overpayment:)
      return nil unless credit_limit&.positive?

      debt = credit_limit - available_credit
      clamp_overpayment ? [ debt, 0 ].max : debt
    end
  end

  def available_credit_money
    available_credit ? Money.new(available_credit, account.currency) : nil
  end

  def minimum_payment_money
    minimum_payment ? Money.new(minimum_payment, account.currency) : nil
  end

  def annual_fee_money
    annual_fee ? Money.new(annual_fee, account.currency) : nil
  end

  def statement_cycle_configured?
    statement_close_day.present? && account.present?
  end

  def last_statement_close_date(as_of: Date.current)
    return nil unless statement_cycle_configured?

    close = day_of_month_in(as_of, statement_close_day)
    return close if close <= as_of

    day_of_month_in(as_of.prev_month, statement_close_day)
  end

  def previous_statement_close_date(as_of: Date.current)
    last_close = last_statement_close_date(as_of: as_of)
    return nil if last_close.nil?

    day_of_month_in(last_close.prev_month, statement_close_day)
  end

  def next_statement_close_date(as_of: Date.current)
    last_close = last_statement_close_date(as_of: as_of)
    return nil if last_close.nil?

    day_of_month_in(last_close.next_month, statement_close_day)
  end

  def payment_due_date_for(close_date)
    return nil if close_date.nil? || due_day.blank?

    due = day_of_month_in(close_date, due_day)
    due = day_of_month_in(close_date.next_month, due_day) if statement_close_day.present? && due_day < statement_close_day

    due
  end

  def next_payment_due_date(as_of: Date.current)
    last_close = last_statement_close_date(as_of: as_of)
    return nil if last_close.nil?

    due = payment_due_date_for(last_close)
    return nil if due.nil?

    # Give way only once the statement is paid; an unpaid bill stays overdue.
    due = payment_due_date_for(next_statement_close_date(as_of: as_of)) if due < as_of && statement_settled?(as_of: as_of)

    due
  end

  def days_until_due(as_of: Date.current)
    due = next_payment_due_date(as_of: as_of)
    return nil if due.nil?

    (due - as_of).to_i
  end

  def last_statement_balance_money(as_of: Date.current)
    last_close = last_statement_close_date(as_of: as_of)
    return nil if last_close.nil?

    statement_ledger(as_of: as_of, last_close: last_close)[:closed]
  end

  def accrued_since_last_close_money(as_of: Date.current)
    last_close = last_statement_close_date(as_of: as_of)
    return nil if last_close.nil?

    accrued_after_bill_settlement(statement_ledger(as_of: as_of, last_close: last_close))
  end

  # The interest the cycle that opened after `last_close` has accrued through
  # `as_of`, or through the cycle's own close once that has passed. Each day
  # charges its balance at the daily rate of the card's basis: a charge counts
  # from the day it posts, a payment or other credit from the day after, and a
  # day in credit charges nothing. The days are summed and rounded once. The
  # current APR applies to the whole cycle.
  #
  # Nothing accrues when the statement that closed on `last_close` was paid in
  # full by its due date. Until it is paid, the figure shows what the cycle is
  # accruing, which is what it costs if the payment misses that date.
  #
  # nil without an APR, when an entry is in another currency, or when the
  # balance records have not been built yet.
  def cycle_interest_money(last_close:, as_of: Date.current)
    return nil if apr.blank? || !statement_cycle_configured?

    currency = account.currency
    first_day = last_close + 1
    last_day = [ as_of, day_of_month_in(last_close.next_month, statement_close_day) ].min
    return Money.new(0, currency) if last_day < first_day

    scoped = account.entries.excluding_pending.excluding_split_parents
    return nil unless all_in_currency?(scoped.where(date: ..last_day), currency)

    paid = statement_paid_by_due_date?(scoped, last_close, [ as_of, last_day ].min)
    return nil if paid.nil?
    return Money.new(0, currency) if paid

    balance_days = cycle_balance_days(scoped, first_day, last_day)
    return nil if balance_days.nil?

    interest = balance_days * apr / 100 / DAY_COUNT_BASES.fetch(day_count_convention)
    Money.new(interest.round(Money::Currency.new(currency).default_precision || 2), currency)
  end

  # One read of the statement cycle for the Overview tab. The view needs the
  # closed statement, what has happened since, and whether the bill is settled;
  # building them together keeps those figures on one `as_of` and avoids
  # re-querying the same entries for each line.
  def statement_summary(as_of: Date.current, viewer:)
    return nil unless statement_cycle_configured?

    last_close = last_statement_close_date(as_of: as_of)
    ledger = statement_ledger(as_of: as_of, last_close: last_close)
    balance = ledger[:closed]
    credits = ledger[:credits]
    remaining = statement_remaining(balance, credits)
    last_due_date = payment_due_date_for(last_close)

    StatementSummary.new(
      balance: balance,
      remaining: remaining,
      charges: ledger[:charges],
      credits: credits,
      payments_applied: payments_applied_to_open_cycle(ledger),
      accrued: accrued_after_bill_settlement(ledger),
      adjustments: ledger[:adjustments],
      due_date: statement_due_date(last_due_date, remaining, as_of),
      last_due_date: last_due_date,
      next_close: next_statement_close_date(as_of: as_of),
      status: statement_status(balance: balance, remaining: remaining, due_date: last_due_date, as_of: as_of),
      scheduled_payment: next_scheduled_payment(as_of: as_of, viewer: viewer),
      estimated_interest: cycle_interest_money(last_close: last_close, as_of: as_of),
      monthly_rate: monthly_rate
    )
  end

  # Takes the closed balance when the caller already has it, so the Overview
  # does not build the statement cycle a second time.
  def minimum_payment_shortfall?(as_of: Date.current, balance: last_statement_balance_money(as_of: as_of))
    minimum = minimum_payment_money
    return false if minimum.nil? || balance.nil?

    balance > minimum
  end

  private
    # The figures for the statement cycle. Charges and payments come from the
    # entries in the open cycle. What was owed at the close, and what is owed
    # now, come from the account's balance records: the same records the account
    # header reads, so the two cannot disagree, and no entry history has to be
    # replayed. What is left over between them is the balance updates made in the
    # open cycle, which keeps the figures adding up to the current debt.
    #
    # A part is nil when it holds an entry we cannot add up in the account's own
    # currency, or when the balance records have not been built yet.
    def statement_ledger(as_of:, last_close:)
      currency = account.currency
      scoped = account.entries.excluding_pending.excluding_split_parents
      closed_scope = scoped.where(date: ..last_close)
      window_scope = scoped.where(date: (last_close + 1)..as_of)

      closed_known = all_in_currency?(closed_scope, currency)
      window_known = all_in_currency?(window_scope, currency)

      closed = closed_known ? balance_record_on_or_before(last_close, closed_scope) : nil

      transactions = window_scope.where(entryable_type: "Transaction")
      charges = window_known ? BigDecimal(transactions.where("amount > 0").sum(:amount).to_s) : nil
      credits = window_known ? BigDecimal(transactions.where("amount < 0").sum(:amount).to_s) : nil

      # Without a known closed bill there is nothing to measure an update
      # against, so the fallback keeps the net of the open cycle and leaves
      # updates out.
      adjustments = nil
      if window_known && charges && credits
        if closed.nil?
          adjustments = BigDecimal(0)
        else
          current = balance_record_on_or_before(as_of, scoped.where(date: ..as_of))
          adjustments = current && (current.amount - closed.amount - charges - credits)
        end
      end

      {
        closed: closed,
        charges: charges && Money.new(charges, currency),
        credits: credits && Money.new(credits, currency),
        adjustments: adjustments && Money.new(adjustments, currency)
      }
    end

    # Every entry in the scope is in the account's currency. Compared by count,
    # because `where.not(currency:)` never matches an entry with no currency.
    def all_in_currency?(scope, currency)
      scope.where(currency: currency).count == scope.count
    end

    # The balance the account had on the given date, or on the nearest earlier
    # date that has one. Nothing in the scope means nothing was owed, so zero.
    # nil when the scope has entries but no balance record covers them yet.
    def balance_record_on_or_before(date, scope)
      return Money.new(0, account.currency) if scope.none?

      amount = account.balances
        .where(currency: account.currency, date: ..date)
        .order(date: :desc)
        .pick(:end_balance)

      amount && Money.new(amount, account.currency)
    end

    # Payments made after the close settle the closed bill first, up to its
    # amount. Only the surplus, if any, reduces what was charged or adjusted in
    # the open cycle, so the figure is the debt still owed on that cycle (or a
    # credit when the surplus exceeds it).
    def accrued_after_bill_settlement(ledger)
      charges, adjustments = ledger.values_at(:charges, :adjustments)
      applied = payments_applied_to_open_cycle(ledger)
      return nil if charges.nil? || adjustments.nil? || applied.nil?

      Money.new(charges.amount + adjustments.amount - applied.amount, charges.currency)
    end

    # The part of the payments since the close that reduced the open cycle. The
    # payments settle the closed bill first, up to its amount, so only the
    # surplus is left for the open cycle. Without a known closed bill there is
    # nothing to settle first, so every payment counts against the open cycle.
    # Nil when the charges or payments cannot be totalled.
    def payments_applied_to_open_cycle(ledger)
      charges, credits, balance = ledger.values_at(:charges, :credits, :closed)
      return nil if charges.nil? || credits.nil?

      bill = balance ? [ balance.amount, 0 ].max : 0
      Money.new([ credits.amount.abs - bill, 0 ].max, charges.currency)
    end

    # What is still owed on the closed bill after payments since the close. A
    # closed balance that is itself a credit is kept as a credit, so the card
    # shows what the cardholder is owed rather than hiding it as zero.
    def statement_remaining(balance, credits)
      return nil if balance.nil? || credits.nil?
      return balance unless balance.positive?

      Money.new([ balance.amount + credits.amount, 0 ].max, balance.currency)
    end

    # Once the closed bill is settled, its due date is no longer the next one
    # the cardholder has to meet. Keep an unpaid bill's date in place even when
    # it has passed, so the Overview still says it is overdue.
    def statement_due_date(last_due_date, remaining, as_of)
      return last_due_date if last_due_date.nil? || remaining.nil?
      return last_due_date if remaining.positive? || last_due_date >= as_of

      payment_due_date_for(next_statement_close_date(as_of: as_of))
    end

    def statement_status(balance:, remaining:, due_date:, as_of:)
      return nil if balance.nil? || remaining.nil?
      return :no_balance unless balance.positive?
      return :paid if remaining.zero?
      return :overdue if due_date.present? && due_date < as_of
      return :partial if remaining.amount < balance.amount

      :unpaid
    end

    # Use the earliest open occurrence, even when its date has passed: an
    # unpaid scheduled payment is exactly the one the cardholder needs to see.
    # The cached next_expected_date can stay stale after a manual payment, so
    # fall back to it only when the series has no occurrence yet.
    def next_scheduled_payment(as_of:, viewer:)
      RecurringTransaction
        .accessible_by(viewer)
        .where(destination_account_id: account.id)
        .active
        .includes(:recurring_occurrences)
        .filter_map do |payment|
          due_date = next_open_due_date(payment, as_of)
          ScheduledPayment.new(payment: payment, due_date: due_date) if due_date
        end
        .min_by(&:due_date)
    end

    def next_open_due_date(payment, as_of)
      occurrence = payment.recurring_occurrences.select(&:scheduled?).min_by(&:due_on)
      return occurrence.effective_due_on if occurrence

      payment.next_expected_date if payment.next_expected_date >= as_of
    end

    def monthly_rate
      apr / 12 if apr.present?
    end

    # Whether the statement that closed on `close` was paid in full by its due
    # date, which is what grace on the next cycle's purchases turns on. Unlike
    # statement_settled?, a payment after the due date does not count. Without
    # a due day, the payments up to `as_of` decide. nil when the closed balance
    # is unknown.
    def statement_paid_by_due_date?(scoped, close, as_of)
      balance = balance_record_on_or_before(close, scoped.where(date: ..close))
      return nil if balance.nil?
      return true unless balance.positive?

      due = payment_due_date_for(close)
      cutoff = due ? [ due, as_of ].min : as_of
      credits = scoped.where(entryable_type: "Transaction", date: (close + 1)..cutoff).where("amount < 0")
      return nil unless all_in_currency?(credits, account.currency)

      credits.sum(:amount).abs >= balance.amount
    end

    # The sum over the cycle's days of each day's balance before that day's
    # credits, a day in credit counting as zero. A balance record's end
    # balance already includes the credits posted that day; on a card they are
    # its inflows, so adding them back gives the balance a payment does not
    # reduce until the next day. A day without a record keeps the last one's
    # end balance. nil when there are entries but no balance records yet.
    def cycle_balance_days(scoped, first_day, last_day)
      records = account.balances
        .where(currency: account.currency, date: first_day..last_day)
        .pluck(:date, :end_balance, :cash_inflows)
        .index_by(&:first)
      carried = account.balances
        .where(currency: account.currency, date: ...first_day)
        .order(date: :desc)
        .pick(:end_balance)

      if records.empty? && carried.nil?
        return scoped.where(date: ..last_day).none? ? 0 : nil
      end

      carried ||= 0
      (first_day..last_day).sum do |date|
        if (record = records[date])
          _, end_balance, inflows = record
          carried = end_balance
          [ end_balance + inflows, 0 ].max
        else
          [ carried, 0 ].max
        end
      end
    end

    def statement_settled?(as_of: Date.current)
      last_close = last_statement_close_date(as_of: as_of)
      return false if last_close.nil?

      ledger = statement_ledger(as_of: as_of, last_close: last_close)
      balance = ledger[:closed]
      return false if balance.nil?
      return true unless balance.positive?

      credits = ledger[:credits]
      return false if credits.nil?

      credits.amount.abs >= balance.amount
    end

    def day_of_month_in(base_date, day)
      Date.new(base_date.year, base_date.month, [ day, base_date.end_of_month.day ].min)
    end
end
