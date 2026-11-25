require "test_helper"

class RetirementPlan::SimulationTest < ActiveSupport::TestCase
  # The first day of a year, so the first row is a whole year and the hand
  # tables below hold. A first row that starts later in the year is tested on
  # its own.
  AS_OF = Date.new(2026, 1, 1)
  Stream = RetirementPlan::Simulation::Stream

  test "0% return and no inflation: each year adds the contribution and nothing compounds" do
    sim = simulation(expected_annual_return: 0, annual_contribution: 10_000)

    assert_equal [ 110_000, 120_000, 130_000 ], sim.rows.first(3).map(&:end_value)
  end

  test "5% return with no inflation matches the simple projection's hand-computed table to the cent" do
    sim = simulation(expected_annual_return: BigDecimal("0.05"), annual_contribution: 10_000)

    assert_equal %w[115000.0 130750.0 147287.5], sim.rows.first(3).map { |r| r.end_value.round(2).to_s("F") }
  end

  # 100,000 at 5%, a contribution of 10,000 that grows with 3% inflation:
  #   year 1: 100,000.00 × 1.05 + 10,000.00 = 115,000.00  → ÷ 1.03   = 111,650.49
  #   year 2: 115,000.00 × 1.05 + 10,300.00 = 131,050.00  → ÷ 1.0609 = 123,527.19
  #   year 3: 131,050.00 × 1.05 + 10,609.00 = 148,211.50  → ÷ 1.092727 = 135,634.52
  test "3% inflation matches a hand-computed table, nominal and in today's money" do
    sim = simulation(expected_annual_return: BigDecimal("0.05"), inflation_rate: BigDecimal("0.03"), annual_contribution: 10_000)
    rows = sim.rows.first(3)

    assert_equal %w[115000.0 131050.0 148211.5], rows.map { |r| r.end_value.round(2).to_s("F") }
    assert_equal %w[111650.49 123527.19 135634.52], rows.map { |r| r.end_value_real.round(2).to_s("F") }
  end

  test "a withdrawal comes out at the start of the year, before that year's growth" do
    sim = simulation(expected_annual_return: BigDecimal("0.05"), retirement_year: AS_OF.year,
                     streams: [ Stream.new(kind: "expense", annual_amount: 40_000) ])

    assert_equal BigDecimal("40000"), sim.rows.first.withdrawal
    assert_equal BigDecimal("63000"), sim.rows.first.end_value
  end

  test "before retirement nothing is withdrawn for seeded spending; from the retirement year it is" do
    sim = simulation(retirement_year: AS_OF.year + 2, streams: [ Stream.new(kind: "expense", annual_amount: 1_000, seeded: true) ])

    assert_equal [ 0, 0, 1_000, 1_000 ], sim.rows.first(4).map(&:withdrawal)
    assert_equal [ 10_000, 10_000, 0, 0 ], sim.rows.first(4).map(&:contribution)
  end

  test "a pension is set against spending, and a surplus is reinvested rather than withdrawn as a negative" do
    sim = simulation(retirement_year: AS_OF.year, streams: [
      Stream.new(kind: "expense", annual_amount: 30_000),
      Stream.new(kind: "income", annual_amount: 10_000),
      Stream.new(kind: "income", annual_amount: 35_000, start_year: AS_OF.year + 1)
    ])

    assert_equal [ 20_000, 0 ], sim.rows.first(2).map(&:withdrawal)
    assert_equal [ 0, 15_000 ], sim.rows.first(2).map(&:contribution)
  end

  test "a one-off amount comes out in its year only, before retirement" do
    sim = simulation(retirement_year: AS_OF.year + 5,
                     streams: [ Stream.new(kind: "one_off", annual_amount: 25_000, start_year: AS_OF.year + 1) ])

    assert_equal [ 0, 25_000, 0 ], sim.rows.first(3).map(&:withdrawal)
  end

  # Retired from this year, spending covered exactly by a pension, so the
  # one-off is the only flow: it must come out, not go back in as savings.
  test "a one-off in a retirement year is withdrawn, not reinvested" do
    sim = simulation(retirement_year: AS_OF.year, streams: [
      Stream.new(kind: "expense", annual_amount: 10_000),
      Stream.new(kind: "income", annual_amount: 10_000),
      Stream.new(kind: "one_off", annual_amount: 25_000, start_year: AS_OF.year + 1)
    ])

    assert_equal [ 0, 25_000, 0 ], sim.rows.first(3).map(&:withdrawal)
    assert_equal [ 0, 0, 0 ], sim.rows.first(3).map(&:contribution)
    assert_equal BigDecimal("75000"), sim.rows.second.end_value
  end

  test "a stream with an end year stops after that year" do
    sim = simulation(retirement_year: AS_OF.year,
                     streams: [ Stream.new(kind: "expense", annual_amount: 12_000, end_year: AS_OF.year + 1) ])

    assert_equal [ 12_000, 12_000, 0 ], sim.rows.first(3).map(&:withdrawal)
  end

  test "an indexed stream grows with inflation from today; an unindexed one does not" do
    sim = simulation(retirement_year: AS_OF.year, inflation_rate: BigDecimal("0.03"), streams: [
      Stream.new(kind: "expense", annual_amount: 10_000, indexed: true),
      Stream.new(kind: "expense", annual_amount: 5_000, indexed: false)
    ])

    assert_equal [ BigDecimal("15000"), BigDecimal("15300"), BigDecimal("15609") ], sim.rows.first(3).map(&:withdrawal)
  end

  test "the table runs to the end age, and the age is the year minus the birth year" do
    sim = simulation(birth_year: 1980, end_age: 90)

    assert_equal AS_OF.year, sim.rows.first.year
    assert_equal 2070, sim.rows.last.year
    assert_equal [ 46, 90 ], [ sim.rows.first.age, sim.rows.last.age ]
  end

  # 50,000 at 0% with 20,000 a year of spending from today: 30,000 after the
  # first year, 10,000 after the second, and the third year's 20,000 cannot be
  # met from the 10,000 left. The money runs out in the third year, at 48.
  test "the money runs out in the first year a withdrawal cannot be met, and the balance stays at zero" do
    sim = simulation(current_assets: 50_000, annual_contribution: 0, retirement_year: AS_OF.year, birth_year: 1980,
                     streams: [ Stream.new(kind: "expense", annual_amount: 20_000) ])

    assert_not sim.survives?
    assert_equal 48, sim.depletion_age
    assert_equal AS_OF.year + 2, sim.depletion_year
    assert_equal [ 30_000, 10_000, 0, 0 ], sim.rows.first(4).map(&:end_value)
  end

  # 40,000 at 0% with 20,000 a year: the second year's withdrawal takes the
  # last 20,000, which is met, and only the third year's cannot be.
  test "a withdrawal that takes exactly what is left is met" do
    sim = simulation(current_assets: 40_000, annual_contribution: 0, retirement_year: AS_OF.year,
                     streams: [ Stream.new(kind: "expense", annual_amount: 20_000) ])

    assert_equal AS_OF.year + 2, sim.depletion_year
    assert_equal [ 20_000, 0 ], sim.rows.first(2).map(&:end_value)
  end

  test "a plan that never runs short survives, with no depletion age" do
    sim = simulation(current_assets: 1_000_000, retirement_year: AS_OF.year, birth_year: 1980,
                     streams: [ Stream.new(kind: "expense", annual_amount: 1_000) ])

    assert sim.survives?
    assert_nil sim.depletion_age
  end

  # Born 1935 with an end age of 90: the plan ended in 2025. With no years to
  # run, no withdrawal is ever tested, so `survives?` would answer true.
  test "an end-age year before the reference year is refused, and the end-age year itself is not" do
    assert_raises(ArgumentError) { simulation(birth_year: 1935, end_age: 90) }
    assert_equal [ AS_OF.year ], simulation(birth_year: 1936, end_age: 90).rows.map(&:year)
  end

  # The reference date is an argument: two runs on different days, with no
  # query and no request, must give the same rows and the same solved year.
  test "the simulation and solver read neither the clock, the database nor the current request" do
    Current.expects(:user).never
    Current.expects(:family).never
    streams = [ Stream.new(kind: "expense", annual_amount: 30_000), Stream.new(kind: "one_off", annual_amount: 5_000, start_year: 2030) ]
    inputs = { as_of: AS_OF, current_assets: 100_000, annual_contribution: 10_000, expected_annual_return: BigDecimal("0.05"),
               inflation_rate: BigDecimal("0.02"), streams: streams, birth_year: 1980, end_age: 90 }

    runs = [ Date.new(2026, 3, 1), Date.new(2031, 9, 30) ].map do |today|
      travel_to(today) do
        figures = nil
        assert_queries_count(0) do
          sim = RetirementPlan::Simulation.new(**inputs, retirement_year: 2040)
          figures = [ sim.rows, sim.survives?, sim.depletion_age, RetirementPlan::Solver.new(**inputs).call ]
        end
        figures
      end
    end

    assert_equal runs.first, runs.last
  end

  # --- The first year --------------------------------------------------------

  # From 1 October, 92 of 2026's 365 days are left.
  test "a first row that starts during the year counts only the part of the year left" do
    sim = simulation(as_of: Date.new(2026, 10, 1), expected_annual_return: BigDecimal("0.05"))
    first = sim.rows.first
    part = Rational(92, 365)

    assert_in_delta 10_000 * part, first.contribution, 0.01
    assert_in_delta 100_000 * (1.05**part - 1), first.growth, 0.01
    assert_equal BigDecimal("10000"), sim.rows.second.contribution, "the next year is whole"
  end

  test "spending in a first row that starts during the year is the part of the year left; a one-off is whole" do
    sim = simulation(as_of: Date.new(2026, 10, 1), retirement_year: 2026, streams: [
      Stream.new(kind: "expense", annual_amount: 36_500),
      Stream.new(kind: "one_off", annual_amount: 1_000)
    ])

    assert_equal BigDecimal("10200"), sim.rows.first.withdrawal, "92 days of 36,500 a year, and the whole one-off"
    assert_equal BigDecimal("36500"), sim.rows.second.withdrawal
  end

  # The reviewer's repro: 100,000 with 10,000 a year at 7% and 3% inflation
  # ended 2027 at 135,490 from 31 December 2026 and at 117,000 from 1 January
  # 2027. A day apart, the two now differ by about a day of growth.
  test "a reference date a day earlier changes the next year's figures by about a day, and not the solved year" do
    inputs = { current_assets: 100_000, annual_contribution: 10_000, expected_annual_return: BigDecimal("0.07"),
               inflation_rate: BigDecimal("0.03"), birth_year: 1980, end_age: 90,
               streams: [ Stream.new(kind: "expense", annual_amount: 20_000, seeded: true, base_year: 2027) ] }
    a = RetirementPlan::Simulation.new(**inputs, as_of: Date.new(2026, 12, 31), retirement_year: 2040)
    b = RetirementPlan::Simulation.new(**inputs, as_of: Date.new(2027, 1, 1), retirement_year: 2040)

    assert_in_delta b.rows.find { _1.year == 2027 }.end_value, a.rows.find { _1.year == 2027 }.end_value, 100
    assert_in_delta b.rows.last.end_value_real, a.rows.last.end_value_real, b.rows.last.end_value_real * BigDecimal("0.001")
    assert_equal RetirementPlan::Solver.new(**inputs, as_of: Date.new(2027, 1, 1)).call.retirement_year,
                 RetirementPlan::Solver.new(**inputs, as_of: Date.new(2026, 12, 31)).call.retirement_year
  end

  # The contribution is in the reference date's money, so it grows with the
  # time since that date: from 1 October, 92 days into 2027.
  test "the contribution grows with inflation from the reference date" do
    sim = simulation(as_of: Date.new(2026, 10, 1), inflation_rate: BigDecimal("0.03"))

    assert_in_delta 10_000 * 1.03**Rational(92, 365), sim.rows.second.contribution, 0.01
    assert_in_delta 10_000 * 1.03**Rational(92 + 365, 365), sim.rows.third.contribution, 0.01
  end

  # --- Streams before retirement ---------------------------------------------

  test "a manual expense before retirement comes out of the contribution, and beyond it out of the portfolio" do
    sim = simulation(retirement_year: 2045,
                     streams: [ Stream.new(kind: "expense", annual_amount: 4_000, start_year: 2028, end_year: 2029),
                                Stream.new(kind: "expense", annual_amount: 20_000, start_year: 2030, end_year: 2033) ])

    rows = sim.rows.select { _1.year.between?(2027, 2034) }
    assert_equal [ 10_000, 6_000, 6_000, 0, 0, 0, 0, 10_000 ], rows.map(&:contribution)
    assert_equal [ 0, 0, 0, 10_000, 10_000, 10_000, 10_000, 0 ], rows.map(&:withdrawal)
  end

  test "a manual income before retirement adds to the contribution" do
    sim = simulation(retirement_year: 2045, streams: [ Stream.new(kind: "income", annual_amount: 12_000, start_year: 2028) ])

    assert_equal [ 10_000, 22_000, 22_000 ], sim.rows.select { _1.year.between?(2027, 2029) }.map(&:contribution)
  end

  # The contribution is income less today's spending, living costs and loan
  # payments included, so a seeded stream is already paid out of it.
  test "a seeded stream does nothing before retirement and counts from it" do
    sim = simulation(retirement_year: 2028, streams: [ Stream.new(kind: "expense", annual_amount: 4_000, seeded: true) ])

    assert_equal [ 10_000, 10_000, 0 ], sim.rows.first(3).map(&:contribution)
    assert_equal [ 0, 0, 4_000 ], sim.rows.first(3).map(&:withdrawal)
  end

  # --- A stream's base year --------------------------------------------------

  # Living costs seeded at 24,000 in 2026: 24,720 in 2027 whether the plan is
  # read in 2026 or reopened in 2027.
  test "an indexed stream grows from its own base year, whatever the reference date" do
    stream = Stream.new(kind: "expense", annual_amount: 24_000, base_year: 2026)
    from_2026 = simulation(inflation_rate: BigDecimal("0.03"), retirement_year: 2026, streams: [ stream ])
    from_2027 = simulation(as_of: Date.new(2027, 1, 1), inflation_rate: BigDecimal("0.03"), retirement_year: 2027, streams: [ stream ])

    assert_equal [ BigDecimal("24720"), BigDecimal("24720") ],
                 [ from_2026, from_2027 ].map { |sim| sim.rows.find { _1.year == 2027 }.withdrawal }
  end

  test "an unindexed stream ignores its base year" do
    sim = simulation(inflation_rate: BigDecimal("0.03"), retirement_year: 2026,
                     streams: [ Stream.new(kind: "expense", annual_amount: 5_000, base_year: 2020, indexed: false) ])

    assert_equal BigDecimal("5000"), sim.rows.first.withdrawal
  end

  private
    def simulation(**overrides)
      RetirementPlan::Simulation.new(**{
        as_of: AS_OF,
        current_assets: 100_000,
        annual_contribution: 10_000,
        expected_annual_return: 0,
        inflation_rate: 0,
        streams: [],
        retirement_year: AS_OF.year + 100,
        birth_year: 1980,
        end_age: 90
      }.merge(overrides))
    end
end
