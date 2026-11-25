# The retirement planner's year-by-year projection.
#
# Pure, like RetirementPlan::Projection: every input is handed in, the
# reference date among them, and nothing here reads the clock, the database or
# the current request.
#
# One row per calendar year, from the reference date's year to the year the
# plan's owner reaches the end age. Within a year the withdrawal comes out
# first and the contribution goes in last:
#
#   V(n + 1) = (V(n) - W(n)) * (1 + r) + C(n)
#
# The first row runs from the reference date to the end of its year, so its
# recurring flows and its growth are for the part of the year left. A one-off
# is paid whole.
#
# Before retirement C is the contribution, less manual spending and plus
# manual income; when spending is more, the rest is withdrawn. Seeded streams
# count only from retirement: the contribution already pays today's living
# costs and loans. From the retirement year, W is spending less income, never
# below zero, and income beyond spending is reinvested as C. One-off amounts
# come out in either case.
#
# `expected_annual_return` is the compound annual return before inflation.
# The contribution is in the reference date's money and grows with
# `inflation_rate` from that date; a stream marked `indexed` grows from its
# own base year. `end_value_real` is the end value in the reference date's
# money.
class RetirementPlan::Simulation
  # A calendar-year span of spending or income. `start_year` nil runs from the
  # reference year; `end_year` nil runs to the end age. A one-off is paid once,
  # in its start year. `annual_amount` is in `base_year`'s money; nil means
  # the reference year's.
  Stream = Data.define(:kind, :annual_amount, :start_year, :end_year, :indexed, :seeded, :base_year) do
    def initialize(kind:, annual_amount:, start_year: nil, end_year: nil, indexed: true, seeded: false, base_year: nil)
      super(kind: kind.to_s, annual_amount: annual_amount.to_d, start_year:, end_year:, indexed:, seeded:, base_year:)
    end

    def active_in?(year, first_year)
      if kind == "one_off"
        year == (start_year || first_year)
      else
        (start_year.nil? || year >= start_year) && (end_year.nil? || year <= end_year)
      end
    end
  end

  Row = Data.define(:year, :age, :start_value, :contribution, :withdrawal, :growth, :end_value, :end_value_real)

  attr_reader :as_of, :retirement_year, :birth_year, :end_age

  def initialize(as_of:, current_assets:, annual_contribution:, expected_annual_return:, inflation_rate:, streams:, retirement_year:, birth_year:, end_age:)
    @as_of = as_of.to_date
    @current_assets = current_assets.to_d
    @annual_contribution = annual_contribution.to_d
    @return_rate = expected_annual_return.to_d
    @inflation_rate = inflation_rate.to_d
    @streams = streams
    @retirement_year = retirement_year
    @birth_year = birth_year
    @end_age = end_age
    raise ArgumentError, "the end-age year #{last_year} is before the reference year #{first_year}" if last_year < first_year
  end

  def first_year
    as_of.year
  end

  def last_year
    birth_year + end_age
  end

  # The part of the first year from the reference date to its end, the
  # reference date included: 1 on the first of January.
  def first_year_fraction
    @first_year_fraction ||= Rational(as_of.end_of_year - as_of + 1, as_of.end_of_year.yday)
  end

  def rows
    @rows ||= build_rows
  end

  def survives?
    depletion_year.nil?
  end

  # The first year whose withdrawal the portfolio cannot meet.
  def depletion_year
    rows
    @depletion_year
  end

  def depletion_age
    depletion_year && depletion_year - birth_year
  end

  # Each year's [contribution, withdrawal], which do not depend on returns.
  # RetirementPlan::MonteCarlo replays them under varying returns.
  def yearly_flows
    @yearly_flows ||= (first_year..last_year).map { |year| flows_for(year, year - first_year) }
  end

  def inflation_rate
    @inflation_rate
  end

  def current_assets
    @current_assets
  end

  def return_rate
    @return_rate
  end

  private
    def build_rows
      value = @current_assets
      @depletion_year = nil

      (first_year..last_year).map do |year|
        contribution, withdrawal = flows_for(year)
        start_value = value

        if @depletion_year.nil? && withdrawal > value
          @depletion_year = year
        end

        after_withdrawal = [ value - withdrawal, 0 ].max
        growth = after_withdrawal * (compound(@return_rate, part_of(year)) - 1)
        value = after_withdrawal + growth + contribution

        Row.new(
          year: year, age: year - birth_year, start_value: start_value,
          contribution: contribution, withdrawal: withdrawal, growth: growth,
          end_value: value, end_value_real: value / compound(@inflation_rate, years_from_as_of(year + 1))
        )
      end
    end

    # Recurring flows are for the part of the year the row covers; a one-off
    # is paid whole. Before retirement the contribution goes in, net of manual
    # streams; from the retirement year spending less income comes out, and
    # income beyond spending goes back in.
    def flows_for(year)
      one_offs = total(year, "one_off")

      net = if year < retirement_year
        manual_spending = total(year, "expense", seeded: false) - total(year, "income", seeded: false)
        manual_spending - @annual_contribution * compound(@inflation_rate, years_from_as_of(year))
      else
        total(year, "expense") - total(year, "income")
      end
      net = prorate(net, year)

      [ [ -net, 0 ].max, [ net, 0 ].max + one_offs ]
    end

    # `seeded` nil counts every stream of the kind.
    def total(year, kind, seeded: nil)
      @streams
        .select { |stream| stream.kind == kind && stream.active_in?(year, first_year) && (seeded.nil? || stream.seeded == seeded) }
        .sum(BigDecimal("0")) { |stream| stream.indexed ? stream.annual_amount * compound(@inflation_rate, year - (stream.base_year || first_year)) : stream.annual_amount }
    end

    def part_of(year)
      year == first_year ? first_year_fraction : 1
    end

    # Multiplied then divided, so a BigDecimal amount keeps its precision.
    def prorate(amount, year)
      part = part_of(year).to_r
      amount * part.numerator / part.denominator
    end

    # Years from the reference date to the start of `year`.
    def years_from_as_of(year)
      year == first_year ? 0 : year - first_year - 1 + first_year_fraction
    end

    # (1 + rate) ** years. A whole number of years stays exact; a fraction of
    # a year goes through BigDecimal#power, which needs a precision.
    def compound(rate, years)
      base = 1 + rate
      years.to_r.denominator == 1 ? base**years.to_i : base.power(BigDecimal(years.numerator) / years.denominator, 20)
    end
end
