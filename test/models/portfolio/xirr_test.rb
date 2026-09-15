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

  # Halving over a year. From its 10% starting guess Newton's first step lands
  # below -100%, outside the domain, so it hands over; bisection finds -50%.
  # Asserting that Newton alone gives up is what proves the fallback ran.
  test "falls back to bisection when newton leaves the domain" do
    flows = [
      [ Date.new(2026, 1, 1), -1_000 ],
      [ Date.new(2027, 1, 1), 500 ]
    ]
    xirr = Portfolio::Xirr.new(flows)

    assert_nil xirr.send(:newton_rate), "the fixture must defeat Newton, or this proves nothing"
    assert_in_delta(-0.5, xirr.rate.to_f, 0.0005)
  end

  # A 10% year on a billion. Newton's steps shrink below TOLERANCE while the
  # present-value residual, in currency units, stays near 1.2e-7: at this
  # magnitude an absolute 1e-9 residual is out of reach in Float. A step that
  # small means Newton stopped moving, not that it solved, so it must hand over
  # rather than report the stalled guess; bisection then finds 10%.
  test "newton hands a stalled step to bisection when the residual is out of reach" do
    flows = [
      [ Date.new(2026, 1, 1), -1_000_000_000 ],
      [ Date.new(2027, 1, 1), 1_100_000_000 ]
    ]
    xirr = Portfolio::Xirr.new(flows)

    assert_nil xirr.send(:newton_rate), "a small step without a small residual is not a solution"
    assert_in_delta 0.1, xirr.rate.to_f, 0.000001
  end

  # A fivefold gain in 30 days annualises to 5^(365/30) - 1, about 3.2e8. That
  # is above RATE_CEILING, so bisection could not find it; Newton must, and to
  # the right magnitude, not merely to some positive number.
  test "newton solves a steep series whose root lies beyond the bisection bracket" do
    rate = Portfolio::Xirr.rate([
      [ Date.new(2026, 1, 1), -1_000 ],
      [ Date.new(2026, 1, 31), 5_000 ]
    ])

    expected = (5.0**(365.0 / 30)) - 1
    assert_operator expected, :>, Portfolio::Xirr::RATE_CEILING
    assert_in_delta expected, rate.to_f, expected * 1e-6
  end

  test "raises when every flow falls on one date" do
    flows = [
      [ Date.new(2026, 3, 2), -1_000 ],
      [ Date.new(2026, 3, 2), 1_000 ]
    ]

    assert_raises(Portfolio::Xirr::NoDurationError) { Portfolio::Xirr.rate(flows) }
    assert_nil Portfolio::Xirr.rate_or_nil(flows)
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
