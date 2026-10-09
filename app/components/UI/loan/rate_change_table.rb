class UI::Loan::RateChangeTable < ApplicationComponent
  # FR-405: the scheduled rate changes a borrower has recorded, in the shape a
  # lender letter uses -- what you pay now, what you will pay, and from when.
  #
  # Future changes only. A change already in effect is not news; it is the
  # current rate, and the card above this table already states it.
  #
  # Every figure is read off the CONTRACTED schedule (#392). The schedule
  # re-amortises the scheduled balance at each recorded rate change over the
  # payments left to the original maturity, which is how a lender sets the
  # minimum repayment. So a change's "new repayment" is the schedule's payment
  # at the first payment on or after its effective date, and its balance is
  # that payment's opening scheduled balance.
  #
  # This reverses #79's move onto `Loan::PayoffProjection`. That move put both
  # columns on the ACTUAL balance net of offset, to match what
  # `current_minimum_payment` then quoted. Both were consistent, but against the
  # wrong base: paying ahead and holding an offset change neither the lender's
  # minimum nor its letter. The current column still reads
  # `current_minimum_payment`, which is now the schedule's payment in force, so
  # the two columns stay on one base.
  attr_reader :loan, :as_of

  # `as_of` is injectable so a caller can pin the reference date, and the
  # schedule tab does: it captures one `today` at the top of the template and
  # passes it here as well as to the summary cards, so the whole tab sits on a
  # single date. Without that, a render crossing midnight on an effective date
  # could show a change in this table that the card above already treats as
  # current -- the same defect CodeRabbit found for the cards on #79.
  #
  # The default is kept so the component stays usable on its own (Lookbook,
  # tests, any future caller with no date to pin); a caller that renders it
  # alongside other date-sensitive output should pass one.
  def initialize(loan:, as_of: Date.current)
    @loan = loan
    @as_of = as_of
  end

  # Nothing is emitted when there is nothing forthcoming -- a variable loan with
  # no scheduled changes renders no empty table and no placeholder.
  def render?
    rows.any?
  end

  # A row for each FORTHCOMING rate change the schedule prices: effective date,
  # new rate, the scheduled balance it lands on, and the repayment before and
  # after. A change with no scheduled payment on or after it (past maturity) is
  # skipped rather than shown with blanks.
  #
  # Two changes before the same payment are priced at that payment on the
  # later rate, so the earlier one never sets a repayment of its own. Only the
  # last change before each payment is listed; listing the earlier one would
  # pair its rate with the later rate's repayment (cubic, #394).
  def rows
    # A fixed-rate loan can still carry rate rows: #14 keeps a loan's rate
    # history when its type changes rather than silently discarding it. Those
    # rows are history, not a forthcoming change, and this table is rendered on
    # every loan's schedule tab.
    return [] unless loan.variable_rate_type?

    @rows ||= priced_changes.filter_map do |effective_date, new_rate, row|
      balance = BigDecimal(row[:beginning_balance].to_s)
      next unless balance.positive?

      {
        effective_date: effective_date,
        current_rate: current_rate,
        new_rate: BigDecimal(new_rate.to_s),
        balance: Money.new(balance, currency),
        current_payment: current_payment,
        new_payment: Money.new(row[:payment_amount], currency)
      }
    end
  end

  # Today's rate, as a BigDecimal so it can be compared with a row's new rate
  # without float drift.
  def current_rate
    @current_rate ||= BigDecimal(loan.current_variable_rate(as_of).to_s)
  end

  # The same figure the Overview and Schedule cards show. Read from the model
  # rather than recomputed, so the three cannot disagree -- which is #15's
  # headline acceptance criterion.
  def current_payment
    @current_payment ||= loan.current_minimum_payment(as_of: as_of)
  end

  private

    # The loan's own currency; every Money in this table is built with it.
    def currency
      loan.account.currency
    end

    # `Loan#variable_rates` already returns entries in date order, so this
    # preserves that ordering. One parse per entry, not two (Codacy, #79).
    def future_rate_changes
      loan.variable_rates.filter_map do |date, rate|
        effective_date = Date.iso8601(date.to_s)
        [ effective_date, rate ] if effective_date > as_of
      end
    end

    # Each forthcoming change with the schedule row it resizes, keeping only
    # the last change before any one payment. A change past maturity has no
    # row and is dropped.
    def priced_changes
      priced = future_rate_changes.filter_map do |effective_date, new_rate|
        row = schedule_row_at(effective_date)
        [ effective_date, new_rate, row ] if row
      end
      priced.reverse.uniq { |_, _, row| row[:payment_date] }.reverse
    end

    # The first scheduled payment on or after the effective date: the payment a
    # change resizes (the payment clock, C8). A change effective ON a payment
    # date resizes that payment. Read from the in-memory simulation, not the
    # persisted rows, which may be stale.
    def schedule_row_at(effective_date)
      loan.amortization_schedule.payments.find { |payment| payment[:payment_date] >= effective_date }
    end
end
