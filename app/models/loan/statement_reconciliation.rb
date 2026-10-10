require "csv"

class Loan
  # Reconciles a lender statement's interest charges against the engine, with
  # the offset total in force each day (gate G2b, #409).
  #
  # The input is a normalised statement, one row per movement in date order:
  #
  #   date,category,amount,balance,annual_rate,offset
  #
  # `balance` is the statement's running balance after the row (negative while
  # money is owed), `annual_rate` the rate in force after it, and `offset` the
  # linked offset accounts' end-of-day total in force after it. Categories:
  #
  #   loan_disbursal   opens the first charge window
  #   repayment, fee   move the balance; `amount` is signed as the statement
  #                    signs it (a repayment positive, a fee negative)
  #   interest         closes a charge window; `amount` is the charge
  #   rate_change      `amount` is the new rate
  #   offset_balance   `amount` is the new offset total
  #
  # Every change is effective from its own date: interest for a day accrues on
  # that day's end-of-day balance less that day's end-of-day offset (C15, C16).
  # A charge covers [previous charge, this charge) and is compared, rounded
  # once, with `Loan::InterestAccrual` over the same window.
  #
  # Nothing here prints or logs the statement. `problems` and `summary` carry
  # row numbers and counts, never amounts or dates, so they can be quoted from
  # a private run without quoting the statement.
  class StatementReconciliation
    HEADERS = %w[date category amount balance annual_rate offset].freeze
    CATEGORIES = %w[loan_disbursal repayment fee interest rate_change offset_balance].freeze
    BALANCE_MOVEMENTS = %w[loan_disbursal repayment fee interest].freeze

    Row = Data.define(:date, :category, :amount, :balance, :annual_rate, :offset)

    Charge = Data.define(:date, :expected, :actual) do
      def deviation
        (actual - expected).abs
      end
    end

    attr_reader :day_count_convention

    def self.from_csv(source, **options)
      table = CSV.parse(source, headers: true)
      unless table.headers == HEADERS
        raise ArgumentError, "a statement must have the headers #{HEADERS.join(',')}"
      end

      new(table.map(&:to_h), **options)
    end

    # `offset_for` replaces the statement's offset rows with another source of
    # offset change points, called as (from_date, to_date) -> [{ date:, amount: }]
    # -- Loan::OffsetResolver#change_points' shape -- so the same charges can be
    # reconciled through the path production reads offsets from.
    def initialize(rows, day_count_convention: InterestAccrual::DEFAULT_DAY_COUNT_CONVENTION, currency_precision: 2, offset_for: nil)
      @rows = rows.map.with_index(1) { |row, number| parse(row, number) }
      @day_count_convention = day_count_convention.to_s
      @currency_precision = currency_precision
      @offset_for = offset_for
    end

    # Rows that break the statement's own arithmetic. A statement that does not
    # sum to its running balance, or moves its rate or offset without declaring
    # it, cannot reconcile against anything; report it before trusting a charge.
    def problems
      problems = []
      problems << "row 1: the first row must be a loan_disbursal" unless @rows.first&.category == "loan_disbursal"

      @rows.each_cons(2).with_index(2) do |(previous, row), number|
        expected_balance = BALANCE_MOVEMENTS.include?(row.category) ? previous.balance + row.amount : previous.balance
        problems << "row #{number}: breaks the running balance" unless row.balance == expected_balance
        if row.annual_rate != previous.annual_rate && row.category != "rate_change"
          problems << "row #{number}: moves the rate without a rate_change row"
        end
        if row.offset != previous.offset && row.category != "offset_balance"
          problems << "row #{number}: moves the offset without an offset_balance row"
        end
      end

      @rows.each.with_index(1) do |row, number|
        problems << "row #{number}: a rate_change's amount must be its new rate" if row.category == "rate_change" && row.amount != row.annual_rate
        problems << "row #{number}: an offset_balance's amount must be its new offset" if row.category == "offset_balance" && row.amount != row.offset
      end

      problems
    end

    # One window per interest row: the balance and rate it opens on, and every
    # change inside it as a change point, merged per date so a repayment and an
    # offset move on one day reach the engine as one point.
    def windows
      @windows ||= begin
        windows = []
        window = nil

        @rows.each do |row|
          case row.category
          when "loan_disbursal"
            window = open_window(row)
          when "interest"
            raise ArgumentError, "an interest row comes before the loan_disbursal" unless window

            windows << window.merge(to_date: row.date, expected: row.amount.abs)
            window = open_window(row)
          else
            next unless window

            point = window[:points][row.date] ||= { date: row.date }
            case row.category
            when "rate_change" then point[:rate] = row.annual_rate
            when "offset_balance" then point[:offset] = row.offset
            else point[:balance] = owed(row)
            end
          end
        end

        windows
      end
    end

    def charges
      @charges ||= windows.map do |window|
        actual = InterestAccrual.charge(
          currency_precision: @currency_precision,
          from_date: window[:from_date],
          to_date: window[:to_date],
          balance: window[:opening_balance],
          annual_rate: window[:opening_rate],
          change_points: change_points(window),
          day_count_convention: day_count_convention
        )
        Charge.new(date: window[:to_date], expected: window[:expected], actual: actual)
      end
    end

    # What a private run may report: counts, the largest deviation and the
    # basis. "Within tolerance" is within one unit of the currency's precision
    # (a cent), the tolerance G2a was signed at.
    def summary
      tolerance = BigDecimal("1").div(10**@currency_precision, @currency_precision + 1)
      deviations = charges.map(&:deviation)

      {
        compared: charges.length,
        exact: deviations.count(&:zero?),
        within_tolerance: deviations.count { |deviation| deviation <= tolerance },
        largest_deviation: deviations.max || BigDecimal("0"),
        day_count_convention: day_count_convention
      }
    end

    private
      def open_window(row)
        {
          from_date: row.date,
          opening_balance: owed(row),
          opening_rate: row.annual_rate,
          points: { row.date => { date: row.date, offset: row.offset } }
        }
      end

      def change_points(window)
        points = window[:points].values
        return points unless @offset_for

        # Swap the statement's offsets for the injected source's, keeping the
        # balance and rate points.
        by_date = points.to_h { |point| [ point[:date], point.except(:offset) ] }
        by_date[window[:from_date]][:offset] = BigDecimal("0")
        @offset_for.call(window[:from_date], window[:to_date]).each do |point|
          (by_date[point.fetch(:date)] ||= { date: point.fetch(:date) })[:offset] = BigDecimal(point.fetch(:amount).to_s)
        end
        by_date.values.sort_by { |point| point[:date] }
      end

      # The statement's balance is negative while money is owed; the engine
      # takes the amount owed.
      def owed(row)
        -row.balance
      end

      def parse(row, number)
        category = row.fetch("category")
        raise ArgumentError, "row #{number}: unknown category" unless CATEGORIES.include?(category)

        Row.new(
          date: Date.iso8601(row.fetch("date")),
          category: category,
          amount: BigDecimal(row.fetch("amount")),
          balance: BigDecimal(row.fetch("balance")),
          annual_rate: BigDecimal(row.fetch("annual_rate")),
          offset: BigDecimal(row.fetch("offset"))
        )
      rescue Date::Error, ArgumentError, TypeError, KeyError => error
        raise ArgumentError, error.message.start_with?("row ") ? error.message : "row #{number}: unreadable"
      end
  end
end
