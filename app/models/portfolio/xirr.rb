# The internal rate of return of an irregularly-timed series of cash flows --
# the money-weighted return of contract row R8.
#
# Newton-Raphson with a bisection fallback (R9). Newton converges in a handful
# of iterations on ordinary portfolios; bisection is slower but cannot diverge,
# so it catches the pathological series -- large early withdrawals, near-zero
# terminal values -- where Newton's derivative sends it off to infinity.
#
# ARITHMETIC NOTE. The rest of the engine works in BigDecimal, but root-finding
# needs `(1 + r) ** (days / 365.0)` with a fractional exponent, which BigDecimal
# cannot do without BigMath.exp/log at a chosen precision -- slow, and delicate
# around r near -1. The iteration therefore runs in Float, which carries about
# fifteen significant digits for a figure displayed to two decimal places, and
# the result is returned as a BigDecimal. Amounts are converted once on the way
# in. This is the deliberate exception to the BigDecimal rule and it is recorded
# in the contract.
#
# No gem: convention 1 (minimise dependencies) and this is eighty lines.
class Portfolio::Xirr
  # The flows never change sign, so no rate exists -- money only ever went in, or
  # only ever came out. Callers render "not available"; they must not substitute
  # a guess.
  class NoSignChangeError < StandardError; end

  # Neither method reached the tolerance inside the iteration cap.
  class ConvergenceError < StandardError; end

  # Every flow falls on the same date, so no time passes and no annual rate
  # exists. Without this check the present value is the same at every rate,
  # and Newton returns its starting guess of 10% as if it had solved.
  class NoDurationError < StandardError; end

  Flow = Data.define(:date, :amount)

  DAYS_PER_YEAR = 365.0
  MAX_NEWTON_ITERATIONS = 50
  MAX_BISECTION_ITERATIONS = 200
  TOLERANCE = 1e-9

  # Widest bracket we will search. -0.999999 rather than -1 because the
  # objective function is undefined at exactly -1 (a total loss of every
  # future-dated flow). 1e7 is 1,000,000,000% -- absurd as a return, but the
  # bracket only has to contain the root, not be plausible.
  RATE_FLOOR = -0.999999
  RATE_CEILING = 1.0e7

  attr_reader :flows

  # `flows` is any enumerable of objects answering `date` and `amount`, or
  # [date, amount] pairs. Sign convention: money leaving the investor is
  # negative, money returning to them is positive. The terminal value of the
  # portfolio is the final positive flow.
  def initialize(flows)
    @flows = normalize(flows)
  end

  def self.rate(flows)
    new(flows).rate
  end

  # The annualised money-weighted rate as a BigDecimal (0.0725 == 7.25%).
  def rate
    raise NoSignChangeError, "cash flows never change sign" unless sign_change?
    raise NoDurationError, "cash flows all fall on one date" if flows.map(&:date).uniq.one?

    result = newton_rate || bisection_rate
    raise ConvergenceError, "XIRR did not converge" if result.nil?

    BigDecimal(result.to_s)
  end

  # Non-raising variant for render paths: returns nil where #rate would raise.
  def self.rate_or_nil(flows)
    rate(flows)
  rescue NoSignChangeError, NoDurationError, ConvergenceError
    nil
  end

  private
    def normalize(flows)
      Array(flows).map { |flow|
        if flow.respond_to?(:date) && flow.respond_to?(:amount)
          Flow.new(date: flow.date.to_date, amount: flow.amount.to_f)
        else
          date, amount = flow
          Flow.new(date: date.to_date, amount: amount.to_f)
        end
      }.reject { |flow| flow.amount.zero? }.sort_by(&:date)
    end

    def sign_change?
      flows.any? { |f| f.amount.positive? } && flows.any? { |f| f.amount.negative? }
    end

    def first_date
      @first_date ||= flows.first.date
    end

    # Years elapsed from the first flow, as a Float.
    def years_for(flow)
      (flow.date - first_date).to_i / DAYS_PER_YEAR
    end

    # Present value of every flow at `rate`. The root of this is the answer.
    def present_value(rate)
      flows.sum { |flow| flow.amount / ((1 + rate)**years_for(flow)) }
    end

    def present_value_derivative(rate)
      flows.sum do |flow|
        years = years_for(flow)
        next 0.0 if years.zero?

        -years * flow.amount / ((1 + rate)**(years + 1))
      end
    end

    def newton_rate
      rate = 0.1

      MAX_NEWTON_ITERATIONS.times do
        value = present_value(rate)
        return rate if value.abs < TOLERANCE

        derivative = present_value_derivative(rate)
        return nil if derivative.zero? || !derivative.finite?

        step = value / derivative
        next_rate = rate - step

        # Newton has left the domain; hand over to bisection rather than
        # producing a NaN and calling it a return.
        return nil if next_rate <= RATE_FLOOR || !next_rate.finite?

        return next_rate if (next_rate - rate).abs < TOLERANCE

        rate = next_rate
      end

      nil
    end

    def bisection_rate
      low = RATE_FLOOR
      high = RATE_CEILING

      low_value = present_value(low)
      high_value = present_value(high)
      return nil unless low_value.finite? && high_value.finite?
      # The root is not inside the widest bracket we are willing to search.
      return nil if low_value * high_value > 0

      MAX_BISECTION_ITERATIONS.times do
        mid = (low + high) / 2.0
        mid_value = present_value(mid)

        return mid if mid_value.abs < TOLERANCE || (high - low).abs < TOLERANCE

        if low_value * mid_value < 0
          high = mid
        else
          low = mid
          low_value = mid_value
        end
      end

      nil
    end
end
