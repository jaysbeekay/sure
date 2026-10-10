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

  # #184 (2026-10-01 review note 1): a projection given an explicit `as_of`
  # must split recorded history from the held-flat total at THAT date. Reading
  # the wall clock instead split it wherever today happened to be.
  test "splits history from the held-flat total at the as_of it is given, not today" do
    as_of = Date.new(2024, 1, 10)
    @offset.update!(balance: 375)
    @offset.balances.create!(date: Date.new(2024, 1, 5), balance: 0, cash_inflows: 100, currency: "USD")

    travel_to Date.new(2024, 3, 1) do
      points = Loan::OffsetResolver.new(@loan, as_of: as_of).change_points(Date.new(2024, 1, 1), Date.new(2024, 2, 1))

      assert_equal({ date: as_of, amount: BigDecimal("375") }, points.last,
        "the held-flat total starts on as_of, not on the wall-clock date")
      assert_equal Date.new(2024, 1, 5), points[-2][:date]
    end
  end

  test "no linked offsets produce no change points" do
    @loan.loan_offset_accounts.delete_all

    assert_empty Loan::OffsetResolver.new(@loan).change_points(Date.current, Date.current.next_month)
  end
end
