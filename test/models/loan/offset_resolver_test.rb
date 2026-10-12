require "test_helper"

class Loan::OffsetResolverTest < ActiveSupport::TestCase
  setup do
    @loan = accounts(:loan).loan
    @offset = @loan.account.family.accounts.create!(
      name: "Resolver offset", balance: 0, currency: "USD", accountable: Depository.new
    )
    @loan.loan_offset_accounts.create!(account: @offset)
  end

  test "uses historical end-of-day balances as change points" do
    @offset.balances.create!(date: Date.new(2024, 1, 1), balance: 0, cash_inflows: 100, currency: "USD")
    @offset.balances.create!(date: Date.new(2024, 1, 2), balance: 0, cash_inflows: 250, currency: "USD")

    points = Loan::OffsetResolver.new(@loan).change_points(Date.new(2024, 1, 1), Date.new(2024, 1, 3))

    assert_equal [
      { date: Date.new(2024, 1, 1), amount: BigDecimal("100") },
      { date: Date.new(2024, 1, 2), amount: BigDecimal("250") }
    ], points
  end

  test "holds today's offset total flat for future ranges" do
    travel_to Date.new(2024, 1, 10) do
      @offset.update!(balance: 375)
      points = Loan::OffsetResolver.new(@loan).change_points(Date.current, Date.current.next_month)

      assert_equal [ { date: Date.current, amount: BigDecimal("375") } ], points
    end
  end

  test "uses one balance per account when the range starts after existing history" do
    @offset.balances.create!(date: Date.new(2024, 1, 1), balance: 0, cash_inflows: 100, currency: "USD")
    @offset.balances.create!(date: Date.new(2024, 1, 2), balance: 0, cash_inflows: 250, currency: "USD")

    points = Loan::OffsetResolver.new(@loan).change_points(Date.new(2024, 1, 2), Date.new(2024, 1, 3))

    assert_equal [ { date: Date.new(2024, 1, 2), amount: BigDecimal("250") } ], points
  end

  test "uses the current total instead of today's stored balance" do
    travel_to Date.new(2024, 1, 10) do
      @offset.update!(balance: 375)
      @offset.balances.create!(date: Date.current, balance: 0, cash_inflows: 100, currency: "USD")

      points = Loan::OffsetResolver.new(@loan).change_points(Date.current.prev_day, Date.current.next_month)

      assert_equal({ date: Date.current, amount: BigDecimal("375") }, points.last)
    end
  end

  test "no linked offsets produce no change points" do
    @loan.loan_offset_accounts.delete_all

    assert_empty Loan::OffsetResolver.new(@loan).change_points(Date.current, Date.current.next_month)
  end

  # The payoff projection asks one resolver once per period. Each future
  # period re-ran the offsets' existence check and today's total: on a
  # 360-month loan with two offsets, the one-chart loan page (#390) took 1.18 s
  # against 0.48 s without the projection, the queries themselves answered
  # from the query cache. Within one projection both are fixed, so they are
  # read once.
  test "resolving many future periods reads the offsets and today's total once" do
    @offset.update!(balance: 375)
    resolver = Loan::OffsetResolver.new(@loan)
    ranges = (0...60).map { |n| [ Date.current >> n, Date.current >> (n + 1) ] }

    queries = 0
    counter = ->(*, payload) { queries += 1 unless payload[:name] == "SCHEMA" }
    points = ActiveSupport::Notifications.subscribed(counter, "sql.active_record") do
      ranges.map { |from, to| resolver.change_points(from, to) }
    end

    assert_equal ranges.map { |from, _| [ { date: from, amount: BigDecimal("375") } ] }, points
    assert_operator queries, :<=, 3, "60 future periods ran #{queries} queries"
  end
end
