# A user's retirement plan: the settings behind the FIRE figures.
#
# Per user, not per family: the figures a plan drives are built from the
# accounts its user can see (see #projection), so a family-level plan would
# project a different set of accounts for each member who opened it.
class RetirementPlan < ApplicationRecord
  belongs_to :user
  has_many :streams, class_name: "RetirementPlan::Stream", dependent: :destroy
  has_many :funding_links, class_name: "RetirementPlan::FundingAccount", dependent: :destroy

  validates :safe_withdrawal_rate, presence: true,
                                   numericality: { greater_than: 0, less_than_or_equal_to: 1 }
  validates :expected_annual_return, presence: true,
                                     numericality: { greater_than: -1, less_than_or_equal_to: 1 }
  # Blank means "derive it from income and expenses", which is a different
  # answer from an explicit zero.
  validates :savings_rate, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 1 },
                           allow_nil: true
  validate :percent_inputs_are_numbers

  # The year-by-year planner. Mirrors the database checks.
  MODES = %w[traditional fire].freeze
  validates :end_age, numericality: { only_integer: true, greater_than_or_equal_to: 50, less_than_or_equal_to: 120 }
  validates :birth_year, numericality: { only_integer: true, greater_than_or_equal_to: 1900, less_than_or_equal_to: 2100 },
                         allow_nil: true
  validates :inflation_rate, presence: true, numericality: { greater_than: -1, less_than_or_equal_to: 1 }
  validates :mode, inclusion: { in: MODES }

  # Monte Carlo. Mirrors the database checks.
  validates :return_volatility, presence: true, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 1 }
  validates :success_target, presence: true, numericality: { greater_than: 0, less_than_or_equal_to: 1 }

  # The user's saved plan, or an unsaved one carrying the column defaults.
  # Never writes: opening a page must not create a row.
  def self.for(user)
    find_by(user: user) || new(user: user)
  end

  PERCENT_ATTRIBUTES = %i[safe_withdrawal_rate expected_annual_return savings_rate inflation_rate return_volatility success_target].freeze

  # The form speaks in percent; the columns hold fractions. Blank stays blank,
  # which for the savings rate means "derive it". Input that is not a number
  # is refused, not read as zero: "abc".to_d is 0, and an explicit 0% savings
  # rate switches off the derived one. The attribute keeps what it held, and
  # the error sits on the field the user typed into.
  PERCENT_ATTRIBUTES.each do |attribute|
    define_method(:"#{attribute}_percent") do
      value = public_send(attribute)
      value && (value * 100)
    end

    define_method(:"#{attribute}_percent=") do |percent|
      non_numeric_percents.delete(attribute)

      if percent.blank?
        public_send(:"#{attribute}=", nil)
      elsif (parsed = BigDecimal(percent.to_s.strip, exception: false))
        public_send(:"#{attribute}=", parsed / 100)
      else
        non_numeric_percents << attribute
      end
    end
  end

  # The account types whose balance is money the user could live off:
  # cash, and what is invested. A property or a vehicle is wealth, but not a
  # portfolio a withdrawal rate can be applied to.
  LIQUID_AND_INVESTMENT_TYPES = %w[Depository Investment Crypto].freeze

  # IncomeStatement counts money moved into an investment account as an
  # expense, which is right for a budget. For a FIRE plan it is saving:
  # counted as spending, it would raise the FI number and lower the derived
  # savings rate at once. Loan payments stay in, because until a loan is paid
  # off they are money the user has to find every month.
  SAVING_KINDS = %w[investment_contribution].freeze

  def projection(as_of:)
    RetirementPlan::Projection.new(
      as_of: as_of,
      annual_expenses: income_statement.median_expense(interval: "month", excluding_kinds: SAVING_KINDS).to_d * 12,
      annual_income: income_statement.median_income(interval: "month").to_d * 12,
      current_assets: assets_as_of(as_of).total,
      safe_withdrawal_rate: safe_withdrawal_rate,
      expected_annual_return: expected_annual_return,
      savings_rate: savings_rate,
      retirement_date: retirement_date
    )
  end

  # --- The year-by-year planner ---------------------------------------------

  # Spending a FIRE plan draws down once retired leaves out loan payments as
  # well as contributions: each loan gets its own stream that stops when the
  # loan is paid off, so counting its payment here too would count it twice.
  LIVING_COSTS_EXCLUDED_KINDS = %w[investment_contribution loan_payment].freeze

  # The year-by-year projection for a traditional plan, retiring in the year of
  # the plan's date (or `retirement_year`, when given). Nil until the plan has
  # a birth year and a retirement date: without them there is no end age and
  # no retirement to plan to.
  def simulation(as_of:, retirement_year: retirement_date&.year)
    return nil if birth_year.nil? || retirement_year.nil?

    RetirementPlan::Simulation.new(**simulation_inputs(as_of:), retirement_year: retirement_year)
  end

  # The milestones on the path the planner draws: a quarter, a half, three
  # quarters and all of #projection's FI number, and Coast FI measured to the
  # plan's retirement date. The page hands in the simulation it draws, so in
  # FIRE mode they follow the path to the solved retirement year.
  def milestones(as_of:, simulation: self.simulation(as_of: as_of))
    return [] if simulation.nil?

    RetirementPlan::Milestones.new(
      rows: simulation.rows, current_assets: funding_total(as_of),
      fi_number: projection(as_of: as_of).fi_number,
      expected_annual_return: expected_annual_return, inflation_rate: inflation_rate,
      retirement_year: retirement_date&.year, first_year: as_of.year, birth_year: birth_year
    ).all
  end

  # FIRE mode: the earliest year the money lasts to the end age.
  def solve(as_of:)
    return nil if birth_year.nil?

    RetirementPlan::Solver.new(**simulation_inputs(as_of:)).call
  end

  # --- Monte Carlo -----------------------------------------------------------

  MONTE_CARLO_PATHS = 5_000

  # Fixed by the plan, so a plan always draws the same paths: the same inputs
  # give the same answer on every visit.
  def monte_carlo_seed
    Zlib.crc32(id.to_s)
  end

  # The run for this plan: retiring on its date, or in FIRE mode in the
  # expected-returns year. Nil while the plan cannot be simulated.
  def monte_carlo(as_of:)
    year = monte_carlo_retirement_year(as_of)
    return nil if year.nil? || new_record?

    projection = projection(as_of: as_of)
    RetirementPlan::MonteCarlo.new(
      simulation_inputs: simulation_inputs(as_of:), retirement_year: year,
      annual_income: projection.annual_income, savings_rate: projection.effective_savings_rate,
      volatility: return_volatility, seed: monte_carlo_seed, paths: MONTE_CARLO_PATHS
    )
  end

  # The run's answers as plain values, so a caller can cache them. The
  # confident year is a full run for each candidate year and only FIRE mode
  # shows it, so it is searched for only there.
  def monte_carlo_result(as_of:)
    mc = monte_carlo(as_of: as_of)
    return nil if mc.nil?

    {
      as_of: as_of, retirement_year: mc.retirement_year, success_rate: mc.success_rate,
      stress_success_rate: mc.stress_success_rate,
      confident_year: (mc.confident_year(success_target) if mode == "fire"),
      percentiles: mc.percentiles, heatmap: mc.heatmap,
      expected_annual_return: mc.expected_annual_return, savings_rate: mc.savings_rate
    }
  end

  # The accounts a user may fund the plan from: those they count in their own
  # finances, as the default funding set uses.
  def eligible_funding_accounts
    finance_accounts
  end

  # Seeds the plan's streams from the user's spending and loans, once. Called
  # by the controller after a save, never on a page view, with the page's
  # reference date. The row lock reloads the plan, so two saves that race
  # here seed once between them.
  def seed_streams!(as_of:)
    with_lock do
      next if streams_seeded_on.present?

      seed_living_costs(as_of)
      seed_loans(as_of)
      update!(streams_seeded_on: as_of)
    end
  end

  # Accounts left out of the asset total for want of an exchange rate on the
  # reference date. The card says so rather than showing a quietly low figure.
  def unconverted_account_count(as_of:)
    assets_as_of(as_of).unconverted_count
  end

  private
    def non_numeric_percents
      @non_numeric_percents ||= Set.new
    end

    def percent_inputs_are_numbers
      non_numeric_percents.each { |attribute| errors.add(:"#{attribute}_percent", :not_a_number) }
    end

    AssetTotal = Data.define(:total, :unconverted_count)

    def monte_carlo_retirement_year(as_of)
      return nil if birth_year.nil?
      return retirement_date&.year unless mode == "fire"

      solve(as_of: as_of).retirement_year || (birth_year + end_age)
    end

    def simulation_inputs(as_of:)
      {
        as_of: as_of,
        current_assets: funding_total(as_of),
        annual_contribution: projection(as_of: as_of).annual_contribution,
        expected_annual_return: expected_annual_return,
        inflation_rate: inflation_rate,
        streams: streams.map(&:to_simulation_stream),
        birth_year: birth_year,
        end_age: end_age
      }
    end

    # Linked accounts when the user has picked any, otherwise the default set.
    def funding_total(as_of)
      return assets_as_of(as_of).total if funding_links.empty?

      linked = finance_accounts.where(id: funding_links.select(:account_id))
      asset_total(as_of, linked).total
    end

    # The 12 whole months before the reference date's month.
    def living_costs_period(as_of)
      month_start = as_of.beginning_of_month
      Period.custom(start_date: month_start - 12.months, end_date: month_start - 1.day)
    end

    def seed_living_costs(as_of)
      monthly = income_statement.median_expense(
        interval: "month", excluding_kinds: LIVING_COSTS_EXCLUDED_KINDS, period: living_costs_period(as_of)
      ).to_d
      return unless monthly.positive?

      streams.create!(kind: "expense", source: "seeded_living_costs", indexed: true,
                      name: I18n.t("retirement_plans.streams.seeded.living_costs"), annual_amount: monthly * 12)
    end

    # Each loan's repayment, at the payment in force on the reference date,
    # until the year its projection pays it off. A loan whose projection does
    # not apply (nothing left to pay, or a payment that never clears it) seeds
    # nothing rather than an invented figure.
    def seed_loans(as_of)
      finance_accounts.where(accountable_type: "Loan").includes(:accountable).find_each do |account|
        projection = Loan::PayoffProjection.new(account.accountable, as_of: as_of)
        next unless projection.applicable? && projection.payoff_date

        payment = account.accountable.amortization_schedule&.payment_in_force(as_of)
        next if payment.nil?

        annual = payment.exchange_to(user.family.currency, date: as_of).amount * 12
        streams.create!(kind: "expense", source: "seeded_loan", indexed: false, account: account,
                        name: account.name, annual_amount: annual, end_year: projection.payoff_date.year)
      rescue Money::ConversionError
        next
      end
    end

    # The same scope InvestmentStatement#investment_accounts uses:
    # what this user counts in their own finances. Family-wide would show a
    # member the combined balance of accounts never shared with them.
    def finance_accounts
      user.family.accounts.visible.included_in_reports.included_in_finances_for(user)
    end

    # Account scope passed explicitly, as Goal#median_monthly_expense does, so
    # the figures are this plan's user's whoever happens to be Current.
    def income_statement
      @income_statement ||= IncomeStatement.new(user.family, user: user, accounts: finance_accounts)
    end

    def assets_as_of(as_of)
      @assets_as_of ||= {}
      @assets_as_of[as_of] ||= asset_total(as_of, finance_accounts)
    end

    def asset_total(as_of, accounts)
      currency = user.family.currency
      total = BigDecimal("0")
      unconverted = 0

      latest_balances(as_of, accounts).each do |row|
        total += Money.new(row.balance, row.currency).exchange_to(currency, date: as_of).amount
      rescue Money::ConversionError
        unconverted += 1
      end

      AssetTotal.new(total: total, unconverted_count: unconverted)
    end

    # Each account's latest balance on or before the reference date, in the
    # account's own currency.
    def latest_balances(as_of, accounts)
      # By id rather than `merge`: the finance scope is DISTINCT, which cannot
      # sit in front of DISTINCT ON.
      Balance
        .joins(:account)
        .where(account_id: accounts.where(accountable_type: LIQUID_AND_INVESTMENT_TYPES).select(:id))
        .where("balances.date <= ?", as_of)
        .where("balances.currency = accounts.currency")
        .select("DISTINCT ON (balances.account_id) balances.account_id, balances.balance, balances.currency")
        .order("balances.account_id, balances.date DESC")
    end
end
