require "test_helper"

# What the full planner is built from (#127, 8.2): the seeded streams, the
# funding accounts, and the simulation and solver a plan hands them to.
class RetirementPlan::PlannerInputsTest < ActiveSupport::TestCase
  include EntriesTestHelper

  AS_OF = Date.new(2026, 3, 15)

  setup do
    @family = families(:dylan_family)
    @admin = users(:family_admin)
    @member = users(:family_member)
    RetirementPlan.where(user: [ @admin, @member ]).delete_all
    # Fixture shares would put the admin's accounts, loans and transactions
    # into the member's finances; every figure here is made only of what the
    # test adds.
    AccountShare.where(user: @member).delete_all
    @plan = RetirementPlan.create!(user: @member, birth_year: 1980)
  end

  # --- Seeding --------------------------------------------------------------

  test "reading a plan's simulation seeds nothing" do
    own_account(amount: 1_000)

    assert_no_difference [ "RetirementPlan.count", "RetirementPlan::Stream.count" ] do
      RetirementPlan.for(@member).simulation(as_of: AS_OF)
    end
  end

  # Months in the window (Mar 2025 to Feb 2026): Jan 2026 spends 1,000 plus a
  # 500 contribution and a 700 loan payment; Feb 2026 spends 1,000. Outside
  # it, Jan and Feb 2025 spend 9,000 each. Counting the old months gives a
  # median of 5,000, counting the contribution gives 1,250, and counting the
  # loan payment 1,350. Leaving all three out gives 1,000: 12,000 a year.
  test "living costs are the last 12 months' median, without contributions or loan payments" do
    checking = own_account(amount: 1_000)
    create_transaction(account: checking, date: Date.new(2026, 1, 10), amount: 1_000)
    create_transaction(account: checking, date: Date.new(2026, 1, 11), amount: 500, kind: "investment_contribution")
    create_transaction(account: checking, date: Date.new(2026, 1, 12), amount: 700, kind: "loan_payment")
    create_transaction(account: checking, date: Date.new(2026, 2, 10), amount: 1_000)
    create_transaction(account: checking, date: Date.new(2025, 1, 10), amount: 9_000)
    create_transaction(account: checking, date: Date.new(2025, 2, 10), amount: 9_000)

    @plan.seed_streams!(as_of: AS_OF)
    living = @plan.streams.find_by!(source: "seeded_living_costs")

    assert_equal BigDecimal("12000"), living.annual_amount
    assert_equal [ "expense", true, nil, nil ], [ living.kind, living.indexed, living.start_year, living.end_year ]
  end

  test "no spending on record seeds no living-costs stream" do
    own_account(amount: 1_000)

    @plan.seed_streams!(as_of: AS_OF)

    assert_not @plan.streams.exists?(source: "seeded_living_costs")
  end

  test "a loan seeds its repayment, ending the year it is paid off" do
    # Ahead of its schedule (about 49,400 owed by now), so the contracted
    # repayment clears it before maturity and there is a payoff year to end on.
    loan_account = own_loan(balance: 45_000, term_months: 60)
    projection = Loan::PayoffProjection.new(loan_account.loan, as_of: AS_OF)

    @plan.seed_streams!(as_of: AS_OF)
    stream = @plan.streams.find_by!(source: "seeded_loan")

    next_payment = loan_account.loan.amortization_schedule.payments.find { |payment| payment.date > AS_OF }
    assert_equal next_payment.payment.amount * 12, stream.annual_amount
    assert_equal projection.payoff_date.year, stream.end_year
    assert_equal [ "expense", false, loan_account ], [ stream.kind, stream.indexed, stream.account ]
  end

  # Pins the current behaviour, not a goal: upstream's projection gives a loan
  # behind its contract no payoff date (the contracted repayment leaves a
  # balloon), so seed_loans has no year to end the stream on and seeds nothing.
  # Changing this is a decision about what the plan should assume; this test
  # makes it a visible one.
  test "a loan behind its contract seeds no stream" do
    loan_account = own_loan(balance: 50_000, term_months: 60)
    projection = Loan::PayoffProjection.new(loan_account.loan, as_of: AS_OF)
    assert projection.applicable?, "the loan must still have repayments to make"
    assert_nil projection.payoff_date, "the loan must be behind its contract for this test to mean anything"

    @plan.seed_streams!(as_of: AS_OF)

    assert_not @plan.streams.exists?(source: "seeded_loan")
  end

  test "a loan with nothing left to pay seeds nothing" do
    own_loan(balance: 0, term_months: 60)

    @plan.seed_streams!(as_of: AS_OF)

    assert_not @plan.streams.exists?(source: "seeded_loan")
  end

  test "streams are seeded once: a deleted seeded stream does not come back" do
    checking = own_account(amount: 1_000)
    create_transaction(account: checking, date: Date.new(2026, 2, 10), amount: 1_000)

    @plan.seed_streams!(as_of: AS_OF)
    @plan.streams.destroy_all
    @plan.seed_streams!(as_of: AS_OF)

    assert_equal AS_OF, @plan.reload.streams_seeded_on
    assert_equal 0, @plan.streams.count
  end

  # Two requests that each loaded the plan before either seeded (CodeRabbit on
  # #251): the second must see the first's marker, not its own stale copy.
  test "two copies of a plan loaded before either seeds do not both seed" do
    checking = own_account(amount: 1_000)
    create_transaction(account: checking, date: Date.new(2026, 2, 10), amount: 1_000)
    first = RetirementPlan.find(@plan.id)
    second = RetirementPlan.find(@plan.id)

    first.seed_streams!(as_of: AS_OF)
    assert_nil second.streams_seeded_on, "the second copy must be stale for this to prove anything"

    assert_no_difference "RetirementPlan::Stream.count" do
      second.seed_streams!(as_of: AS_OF)
    end
  end

  # --- Funding accounts -----------------------------------------------------

  test "linked accounts replace the default set of accounts" do
    own_account(amount: 1_000)
    picked = own_account(amount: 5_000)

    default_start = @plan.simulation(as_of: AS_OF, retirement_year: 2050).rows.first.start_value
    @plan.funding_links.create!(account: picked)
    linked_start = RetirementPlan.find(@plan.id).simulation(as_of: AS_OF, retirement_year: 2050).rows.first.start_value

    assert_equal [ BigDecimal("6000"), BigDecimal("5000") ], [ default_start, linked_start ]
  end

  test "an account the user does not count in their finances cannot be linked" do
    admins = Account.create!(family: @family, owner: @admin, accountable: Depository.new, name: "Admin's", currency: "USD", balance: 1)

    assert_not @plan.funding_links.new(account: admins).valid?
  end

  # --- Simulation and solver ------------------------------------------------

  test "the simulation runs on the plan's own settings, streams and contribution" do
    checking = own_account(amount: 100_000)
    create_transaction(account: checking, date: Date.new(2026, 2, 10), amount: -5_000)
    @plan.update!(expected_annual_return: BigDecimal("0.05"), inflation_rate: 0, savings_rate: BigDecimal("0.2"),
                  end_age: 70, retirement_date: Date.new(2040, 1, 1))
    @plan.streams.create!(kind: "expense", name: "Living costs", annual_amount: 30_000)

    sim = @plan.simulation(as_of: AS_OF)

    assert_equal [ 2040, 2050 ], [ sim.retirement_year, sim.last_year ]
    assert_equal BigDecimal("100000"), sim.rows.first.start_value
    assert_equal BigDecimal("12000"), sim.rows.first.contribution, "20% of 60,000 a year of income"
    assert_equal BigDecimal("30000"), sim.rows.find { |r| r.year == 2040 }.withdrawal
  end

  test "without a birth year there is no simulation and no solution" do
    @plan.update!(birth_year: nil, retirement_date: Date.new(2040, 1, 1))

    assert_nil @plan.simulation(as_of: AS_OF)
    assert_nil @plan.solve(as_of: AS_OF)
  end

  test "the traditional plan needs a retirement date; the solver does not" do
    own_account(amount: 1_000_000)
    @plan.update!(retirement_date: nil)

    assert_nil @plan.simulation(as_of: AS_OF)
    assert_equal AS_OF.year, @plan.solve(as_of: AS_OF).retirement_year
  end

  private
    def own_account(amount:)
      account = Account.create!(family: @family, owner: @member, accountable: Depository.new,
                                name: "Checking #{SecureRandom.hex(3)}", currency: "USD", balance: amount)
      Balance.create!(account: account, date: AS_OF, balance: amount, currency: "USD")
      account
    end

    def own_loan(balance:, term_months:)
      Account.create!(
        family: @family, owner: @member, name: "Loan #{SecureRandom.hex(3)}", currency: "USD", balance: balance,
        accountable: Loan.new(rate_type: "fixed", interest_rate: 6, term_months: term_months,
                              initial_balance: 60_000, start_date: AS_OF - 12.months)
      )
    end
end
