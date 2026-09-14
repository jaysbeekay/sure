require "test_helper"

class Portfolio::XirrTest < ActiveSupport::TestCase
  # Contract R9. Money that only ever went one way has no rate of return: there
  # is no r for which the present value crosses zero. Returning a plausible
  # number here would be inventing one.
  test "raises when the series never changes sign" do
    flows = [
      [ Date.new(2026, 1, 1), -1_000 ],
      [ Date.new(2026, 6, 1), -1_000 ]
    ]

    assert_raises Portfolio::Xirr::NoSignChangeError do
      Portfolio::Xirr.rate(flows)
    end

    assert_nil Portfolio::Xirr.rate_or_nil(flows),
               "the render path must degrade to nil rather than raise"
  end

  # A year, a single outlay, a single return: the rate is the plain growth.
  test "solves a simple one year doubling" do
    rate = Portfolio::Xirr.rate([
      [ Date.new(2026, 1, 1), -1_000 ],
      [ Date.new(2027, 1, 1), 2_000 ]
    ])

    assert_in_delta 1.0, rate.to_f, 0.0005, "1000 -> 2000 over one year is 100%"
  end

  test "solves a flat series at zero" do
    rate = Portfolio::Xirr.rate([
      [ Date.new(2026, 1, 1), -1_000 ],
      [ Date.new(2027, 1, 1), 1_000 ]
    ])

    assert_in_delta 0.0, rate.to_f, 0.0005
  end

  # 1,000 in at the start, 1,000 more at six months, 2,200 out at twelve.
  #
  # Sanity check first, because it is the one an author can do in their head:
  # the first 1,000 was invested for a full year and the second for half of one,
  # so the weighted capital is 1,000 + 500 = 1,500, and a 200 gain on 1,500 is
  # 13.3%. Compounding lifts it slightly.
  #
  # Exactly, with t = 182/365 = 0.49863 and x = 1 + r, the closed form is
  #   -1000x - 1000·x^0.50137 + 2200 = 0
  # At x = 1.1346 the left side is -1134.60 - 1065.37 + 2200 ≈ 0.03, so the root
  # is 0.1346.
  test "solves an irregular series with a mid period contribution" do
    rate = Portfolio::Xirr.rate([
      [ Date.new(2026, 1, 1), -1_000 ],
      [ Date.new(2026, 7, 2), -1_000 ],
      [ Date.new(2027, 1, 1), 2_200 ]
    ])

    assert_in_delta 0.1346, rate.to_f, 0.002
  end

  test "handles a loss" do
    rate = Portfolio::Xirr.rate([
      [ Date.new(2026, 1, 1), -1_000 ],
      [ Date.new(2027, 1, 1), 500 ]
    ])

    assert_in_delta(-0.5, rate.to_f, 0.0005)
  end

  # Newton's derivative vanishes or overshoots on steep series; bisection cannot
  # diverge, so the pair must solve what neither does alone.
  test "falls back to bisection when newton leaves the domain" do
    rate = Portfolio::Xirr.rate([
      [ Date.new(2026, 1, 1), -1_000 ],
      [ Date.new(2026, 1, 31), 5_000 ]
    ])

    assert rate.positive?, "a fivefold gain in a month is a very large positive rate"
    assert rate.finite?
  end

  test "ignores zero amounts" do
    rate = Portfolio::Xirr.rate([
      [ Date.new(2026, 1, 1), -1_000 ],
      [ Date.new(2026, 6, 1), 0 ],
      [ Date.new(2027, 1, 1), 2_000 ]
    ])

    assert_in_delta 1.0, rate.to_f, 0.0005
  end

  test "accepts flow objects as well as pairs" do
    flows = [
      Portfolio::Xirr::Flow.new(date: Date.new(2026, 1, 1), amount: -1_000),
      Portfolio::Xirr::Flow.new(date: Date.new(2027, 1, 1), amount: 2_000)
    ]

    assert_in_delta 1.0, Portfolio::Xirr.rate(flows).to_f, 0.0005
  end

  test "orders flows by date regardless of input order" do
    unordered = Portfolio::Xirr.rate([
      [ Date.new(2027, 1, 1), 2_000 ],
      [ Date.new(2026, 1, 1), -1_000 ]
    ])

    assert_in_delta 1.0, unordered.to_f, 0.0005
  end
end
