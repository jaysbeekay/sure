require "digest"

class Loan < ApplicationRecord
  include Accountable

  SUBTYPES = {
    "mortgage" => { short: "Mortgage", long: "Mortgage" },
    "student" => { short: "Student Loan", long: "Student Loan" },
    "auto" => { short: "Auto Loan", long: "Auto Loan" },
    "home_equity" => { short: "Home Equity", long: "Home Equity Loan" },
    "line_of_credit" => { short: "Line of Credit", long: "Line of Credit" },
    "business" => { short: "Business Loan", long: "Business Loan" },
    "other" => { short: "Other Loan", long: "Other Loan" }
  }.freeze

  # Rate types whose interest can move over the life of the loan, and which
  # therefore schedule off the variable-rate path: the base rate applies until
  # a change is recorded in variable_rate_schedule, and offset accounts are
  # available.
  #
  # `adjustable` is here by decision, not by history. It has been an option in
  # the loan form since 2024 (upstream 65db4927) and until now was read by
  # nothing: every branch in the engine tested for "fixed" or "variable", so
  # selecting it produced a loan with no schedule, no payoff chart, no what-if
  # control and no summary cards, and nothing on screen saying why. #14 chose
  # to give it the variable meaning rather than remove the option.
  #
  # Note this is a set of rate types, not a validation: `rate_type` is an
  # unconstrained string column, and PlaidAccount::Liabilities::MortgageProcessor
  # writes it straight from the provider payload. A value outside this list
  # still behaves as `adjustable` did -- deliberately left alone here.
  VARIABLE_RATE_TYPES = %w[variable adjustable].freeze

  # Every rate type the calculator can build a schedule for.
  #
  # THE single authority for that question, in SQL and in Ruby alike.
  # `loans:schedule_version_status` has to express it as a WHERE clause and
  # cannot call `amortizable?`, so before this constant it carried its own copy
  # of the list -- and adding `adjustable` to VARIABLE_RATE_TYPES silently
  # broke it: `rebuild_schedules` builds an adjustable loan's schedule, while
  # the status task's hardcoded %w[fixed variable] did not count it as awaiting
  # one. The task could then exit 0 with a loan still unbuilt, and the runbook
  # treats that exit code as "the prebuild is finished". A false-clean deploy
  # signal is worse than a red one.
  AMORTIZABLE_RATE_TYPES = ([ "fixed" ] + VARIABLE_RATE_TYPES).freeze

  # Loans up to 100 years cover any real mortgage, business, or personal loan
  # term while keeping a rebuild's array allocation, exponentiation, and bulk
  # insert bounded. Matches the DB check constraint in
  # db/migrate/20260903150000_add_amortization_bounds_to_loans.rb.
  MAX_TERM_MONTHS = 1200

  # Which day-count basis this loan's interest accrues on. Held per loan
  # rather than as one global constant because lenders differ: reconciliation
  # against a real statement (#65) showed 43/43 monthly charges resolving under
  # actual/actual where a fixed 365 resolved only 30/43, and that is evidence
  # that a single constant cannot be assumed -- not evidence that actual/actual
  # is right for every lender. `actual_365` stays the default, so an existing
  # loan keeps the figures it already had until someone changes it deliberately.
  DAY_COUNT_CONVENTIONS = InterestAccrual::DAY_COUNT_CONVENTIONS.map(&:to_s).freeze
  # The basis a new loan starts on: 30/360, upstream's flat twelfth (#184,
  # 2026-09-30). It is the column default; a provider sync does not set the
  # column, so a synced loan starts here too, and the user can change it.
  DEFAULT_DAY_COUNT_CONVENTION = "thirty_360".freeze
  # The basis every loan was on before the column existed, and which loans
  # created before #188 still carry. Its schedule signature leaves the basis
  # out, so those loans keep the signature they always had.
  LEGACY_DAY_COUNT_CONVENTION = "actual_365".freeze

  has_many :amortizations, class_name: "LoanAmortization", dependent: :destroy
  has_many :loan_scenarios, dependent: :destroy
  has_many :loan_offset_accounts, dependent: :destroy
  has_many :offset_accounts, through: :loan_offset_accounts, source: :account

  # The account types a loan can be secured by.
  COLLATERAL_ACCOUNTABLE_TYPES = %w[Property Vehicle].freeze

  # The asset that secures this loan, if the owner has said so. Optional, and
  # judged only when the link itself changes: the loan form resubmits the id it
  # already holds on every edit, so a validation that ran on every save would
  # reject any edit of a loan whose asset has since become ineligible.
  belongs_to :collateral_account, class_name: "Account", optional: true
  validate :collateral_account_is_eligible, if: :will_save_change_to_collateral_account_id?

  attr_accessor :offset_account_ids

  # Structured {effective_date, rate} rows from the form. The jsonb column is
  # deliberately NOT mass-assignable: permitting a free-form hash would let a
  # request write arbitrary JSON into a column the calculation reads, and
  # Brakeman flags it correctly (risk R13, #14). The form submits pairs and the
  # column is assembled from them.
  attr_reader :rate_changes

  # `validate`, NOT `before_save`. The method only calls `errors.add`, and
  # errors added from a `before_save` do not stop the write -- only
  # `throw :abort` does -- so under the old registration an unknown offset
  # account id saved cleanly and `sync_offset_accounts` then dropped it,
  # reporting success for a link that was never created (CodeRabbit, #86).
  validate :validate_offset_accounts, if: :offset_account_ids_supplied?
  after_save :sync_offset_accounts, if: :offset_accounts_need_sync?

  # `offset_account_ids` is not a column, so setting it alone leaves the loan
  # unchanged, and Account's nested save (`accepts_nested_attributes_for
  # :accountable`) validates and saves the loan only when this is true. An edit
  # that changed only the offsets was skipped outright: no validation, no sync,
  # and a success notice for a link that never moved (#319). `rate_changes=`
  # avoids the same trap by writing a real column instead.
  def changed_for_autosave?
    super || offset_account_ids_supplied?
  end

  validates :subtype, inclusion: { in: SUBTYPES.keys }, allow_blank: true
  validates :term_months, numericality: { only_integer: true, greater_than: 0, less_than_or_equal_to: MAX_TERM_MONTHS }, allow_nil: true
  validates :interest_rate, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 100 }, allow_nil: true
  validates :day_count_convention, inclusion: { in: DAY_COUNT_CONVENTIONS }
  validate :variable_rate_schedule_entries_are_valid

  # What the borrower put in up front. Not part of the amortisation -- the loan
  # amortises what was actually lent -- but it is what makes leverage readable:
  # a 20,000 deposit against an 80,000 loan is a different position from the
  # same loan against 5,000.
  validates :down_payment, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true

  validates :insurance_rate, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
  # The form's "None" option submits an empty string, which means no type
  # recorded (read as decreasing). Stored as NULL: the column's check
  # constraint admits NULL but not '', so allowing blank here would only move
  # the rejection from a validation error to a database error.
  normalizes :insurance_rate_type, with: ->(value) { value.presence }
  validates :insurance_rate_type, inclusion: { in: Loan::Insurance::RATE_TYPES }, allow_nil: true

  # How much was borrowed for every unit the borrower put in. Nil without a
  # down payment recorded: a loan with no deposit is not infinitely leveraged,
  # it is a loan whose leverage nobody has told us.
  LEVERAGE_BANDS = {
    conservative: 0..4,
    moderate: 4..8,
    high: 8..
  }.freeze

  before_validation :quantize_variable_rate_schedule

  after_save :enqueue_amortization_rebuild, if: :amortization_inputs_changed?

  # Whether the form can hand these values to their native controls.
  #
  # A date or number input applies the WHATWG value sanitization algorithm and
  # silently blanks a value it cannot parse. Rendering a rejected submission
  # back into one would show the user an empty box next to an error about the
  # value they just typed, leaving them nothing to correct. The form falls back
  # to a text input for exactly these cases -- which are the same cases
  # `variable_rate_schedule_entries_are_valid` rejects, so a value that renders
  # as text is always a value the user has been told about.
  def self.renderable_effective_date?(value)
    return true if value.blank?

    Date.iso8601(value.to_s)
    true
  rescue ArgumentError, TypeError
    false
  end

  # Companion to `renderable_effective_date?` for the rate column, with the
  # same reason: a number input silently blanks what it cannot parse.
  def self.renderable_rate?(value)
    return true if value.blank?

    BigDecimal(value.to_s).finite?
  rescue ArgumentError, TypeError
    false
  end

  # The contracted repayment, for a loan that has exactly one.
  #
  # Deliberately still nil for a variable loan even though it now has a
  # schedule: such a loan does not HAVE a single monthly payment, and quoting
  # the one it opened with would be a stale figure presented as a current one.
  # `current_minimum_payment` is the figure a lender quotes today (#392).
  def monthly_payment
    return nil if term_months.nil? || interest_rate.nil? || rate_type != "fixed"
    # Non-positive, not just zero: `amortizable?` rejects both, so anything that
    # slips past here would fall through to a nil schedule instead of a payment.
    return Money.new(0, account.currency) if original_balance.amount <= 0 || term_months <= 0

    amortization_schedule&.periodic_payment
  end

  # Everyone who can see the loan's account, or will once it is saved: the rule
  # behind both the collateral and the offset links.
  def self.viewers_of(loan_account)
    users = loan_account.family.users
    # A new account in a family that shares by default is visible to everyone in
    # it the moment it exists, but its shares are written after validation.
    return users.to_a if loan_account.new_record? && loan_account.family.share_all_by_default?

    users.select { |user| loan_account.shared_with?(user) }
  end

  # The account this loan is being saved through, when it is. `loan.account` is
  # read from the database (and is nil for a loan being created), so on a save
  # through the account it describes the account as it WAS: a request that changes
  # the currency and the collateral together would be judged on the old currency.
  # Account hands itself over before validating; a loan saved on its own falls
  # back to `account`.
  attr_writer :owning_account

  def owning_account
    @owning_account || account
  end

  # What is wrong with the link as it stands: an id that names no account is
  # refused here, as the foreign key would otherwise raise it as a server error,
  # and a blank id is simply no link. Used by the validation and, for a loan being
  # created, by Account.
  def collateral_problems(loan_account: owning_account)
    return [] if collateral_account_id.blank?
    return [ "does not exist" ] if collateral_account.nil?

    collateral_ineligibilities_for(collateral_account, loan_account: loan_account)
  end

  # Why `account` cannot secure this loan; empty when it can. The one definition
  # shared by the validation and by the form's candidate list, so the list never
  # offers an account the save would refuse.
  #
  # The checks that need the loan's own account are skipped until it exists: a
  # loan being created is validated before it is attached to one.
  # `viewers` lets a caller judging many accounts against one loan work the
  # loan's viewers out once instead of once per account.
  def collateral_ineligibilities_for(account, loan_account: owning_account, viewers: nil)
    return [] if account.nil?

    unless COLLATERAL_ACCOUNTABLE_TYPES.include?(account.accountable_type)
      return [ "must be a property or vehicle" ]
    end

    problems = []

    if loan_account&.family
      # Another family's account has no standing to be visible to this one's
      # viewers, so the family is the only thing worth saying about it.
      return [ "must belong to the same family as the loan" ] unless account.family_id == loan_account.family_id

      problems << "must use the same currency as the loan" unless account.currency == loan_account.currency

      invisible = (viewers || collateral_viewers(loan_account)).reject { |user| account.shared_with?(user) }
      if invisible.any?
        problems << "must be visible to every loan viewer (missing: #{invisible.map(&:display_name).join(", ")})"
      end
    end

    problems
  end

  # The accounts a viewer may pick as this loan's collateral: assets of the right
  # type in the loan's family that they can see and that the save would accept.
  # `family` stands in for the loan account's when the loan has none yet.
  # `currency` narrows the list when the loan has no account to read one from.
  def self.collateral_candidates_for(loan, viewer:, family: nil, currency: nil)
    family ||= loan.account&.family
    return Account.none unless family && viewer

    scope = Account.accessible_by(viewer).visible
      .where(family_id: family.id, accountable_type: COLLATERAL_ACCOUNTABLE_TYPES)
    scope = scope.where(currency: currency) if currency.present? && loan.account.nil?

    loan_account = loan.owning_account
    viewers = loan.send(:collateral_viewers, loan_account) if loan_account&.family
    scope.order(:name)
      .select { |candidate| loan.collateral_ineligibilities_for(candidate, loan_account: loan_account, viewers: viewers).empty? }
  end

  # Drops the memoized schedule after an offset link changes. The contracted
  # schedule does not read offsets, but a link change is the moment a caller
  # holding this loan expects every figure to be read afresh; projections are
  # never memoized (#payoff_projection), so there is nothing else to drop.
  def invalidate_offset_cache!
    clear_amortization_schedule_cache!
  end

  # What the loan was written for, which is not always what the account has
  # been seen holding.
  #
  # `initial_balance` is the recorded contractual principal. The account form
  # writes it beside the opening valuation, so for a loan created here the two
  # agree. Plaid's student-loan import writes `origination_principal_amount`
  # into it and Redbark writes `originalLoanAmount`, and there they can
  # disagree by the whole of the repayment history: a loan imported after
  # years of payments has a first tracked valuation part way down the curve,
  # not the amount borrowed.
  #
  # Every figure measured against what was borrowed reads this: the schedule's
  # principal (and so its repayment, interest and payoff date), the insurance
  # base, how much has been repaid, and the leverage against the deposit.
  # Taking the first valuation instead understated all of them for such a
  # loan, and amortised the wrong principal from the real origination date.
  #
  # Falls back to the first tracked valuation when no principal was recorded,
  # which is every loan whose import does not send one. Non-positive counts as
  # unrecorded: an import can write a zero or a negative, and neither is an
  # amount borrowed. (Upstream's definition, adopted by #184 phase 2.)
  #
  # Memoized per instance (and cleared alongside the calculator cache) so a
  # single check-then-rebuild cycle reads Account's mutable, unlocked
  # valuation/currency once and reuses that exact reading everywhere --
  # otherwise the signature persisted with a schedule could describe a
  # different balance than the one actually used to calculate it if a
  # concurrent Account update lands between the two reads. Assigning
  # `initial_balance` and `reload` drop it, since it now reads a Loan column
  # too.
  def original_balance
    @original_balance ||= begin
      recorded_principal = initial_balance
      if recorded_principal&.positive?
        Money.new(recorded_principal, account.currency)
      else
        Money.new(account.first_valuation_amount, account.currency)
      end
    end
  end

  # The principal is a schedule input: a loan edited in memory must not keep
  # amortising the principal it was loaded with.
  def initial_balance=(value)
    clear_amortization_schedule_cache!
    super
  end

  def reload(*)
    clear_amortization_schedule_cache!
    super
  end

  # The date the loan was drawn down: the recorded one when the borrower knows
  # it, otherwise the account's opening anchor. The ONE definition the
  # schedule's payment dates and accrual start are built from, so counting
  # months from it (#months_elapsed) agrees with the schedule's own numbering.
  #
  # Deliberately not upstream's `start_date || first_valuation&.date ||
  # opening_anchor_date`: the fork's schedule anchors on the opening anchor,
  # and two origins is how a progress card ends up on a different instalment
  # from the table beside it.
  def origination_date
    start_date || account_opening_anchor_date
  end

  # The insurance policy charged alongside this loan's instalments, or nil when
  # no premium is recorded or there is no schedule to charge it against. Read
  # #total_insurance for a figure that is always money.
  #
  # Memoised against the schedule instance and the policy's own inputs rather
  # than cleared by attribute writers: `amortization_schedule` already hands
  # back a new instance whenever any of ITS inputs move (its signature), so
  # keying on that instance covers the schedule's inputs without listing them
  # twice.
  def insurance
    return nil unless insurance_rate&.positive? && amortizable?

    key = [ amortization_schedule, insurance_rate, insurance_rate_type, original_balance ]
    return @insurance if defined?(@insurance) && @insurance_key == key

    @insurance_key = key
    @insurance = Loan::Insurance.for(self)
  end

  def total_insurance
    insurance&.total || Money.new(0, account.currency)
  end

  # Everything the loan costs the borrower: what the schedule has them repay
  # (principal and interest, the Schedule tab's own "Total Cost") plus the
  # premium charged alongside. Read off the schedule rather than re-added from
  # its parts, so with no premium the two figures are the same figure. Nil when
  # there is no schedule to read an interest figure from, because a cost
  # without interest in it would understate the loan rather than decline to
  # answer.
  def total_cost
    schedule = amortization_schedule
    return nil if schedule.nil?

    schedule.total_paid + total_insurance
  end

  # How far into the term the loan is, measured from origination rather than
  # from `start_date` alone: a loan drawn down before the account tracking it
  # was created has no start_date, and #origination_date already answers that
  # from the account.
  #
  # A month counts once it has been served in full, so a loan originated on the
  # 15th is one month in on the 15th of the next month, not on the 1st. Clamped
  # to the term: a loan running past its last payment is finished, not further
  # in than it can be. Counted on the calendar the schedule pays on
  # (`origination >> n`), so the instalment it names is the one the schedule
  # beside it has due.
  def months_elapsed(as_of: Date.current)
    origin = origination_date
    return 0 if origin.nil? || term_months.nil? || as_of < origin

    months = (as_of.year * 12 + as_of.month) - (origin.year * 12 + origin.month)
    months -= 1 if origin + months.months > as_of

    months.clamp(0, term_months)
  end

  def remaining_months(as_of: Date.current)
    return nil if term_months.nil?

    [ term_months - months_elapsed(as_of: as_of), 0 ].max
  end

  def finished?(as_of: Date.current)
    return nil if term_months.nil?

    months_elapsed(as_of: as_of) >= term_months
  end

  # What is still owed after a given scheduled payment, read off the schedule
  # rather than re-derived, so it cannot drift from the table beside it.
  def remaining_balance_at(payment_number)
    return nil unless payment_number&.positive?

    amortization_schedule&.payments&.dig(payment_number - 1)&.ending_balance
  end

  # One instalment, split into what it repays, what it costs and what it
  # insures, with each part as a share of the whole. Defaults to the payment
  # the loan is on as of `as_of`, which the caller supplies so the instalment
  # agrees with every other figure it shows for that date.
  #
  # The ratios are for a progress bar, so they are floats summing to 1 rather
  # than money. A zero payment -- an interest-free loan repaid in full by its
  # opening instalment -- gives zeroes rather than a division by zero.
  def payment_breakdown(payment_number: nil, as_of: Date.current)
    schedule = amortization_schedule
    return nil if schedule.nil?

    if payment_number.nil?
      # A finished loan is on no instalment; the clamp below would otherwise
      # answer with the final, already-paid one as though it were current. The
      # same holds once a schedule that rounding cleared early has run out,
      # though the term has not.
      elapsed = months_elapsed(as_of: as_of)
      return nil if elapsed >= term_months || elapsed >= schedule.payments.size

      payment_number = elapsed + 1
    end

    payment = schedule.payments[payment_number.clamp(1, schedule.payments.size) - 1]
    return nil if payment.nil?

    premium = insurance&.premium_for(payment.number)&.amount || Money.new(0, account.currency)
    total = payment.principal + payment.interest + premium

    {
      number: payment.number,
      date: payment.date,
      principal: payment.principal,
      interest: payment.interest,
      insurance: premium,
      total: total,
      ratios: payment_ratios(payment.principal, payment.interest, premium, total)
    }
  end

  # How much of what was borrowed has been repaid, as a fraction, measured
  # against the account's current balance rather than the schedule: the
  # schedule says what was promised, the balance says what happened.
  def balance_paid_ratio
    borrowed = original_balance.amount
    return nil unless borrowed.positive?

    balance = account&.balance
    return nil if balance.nil?

    (1 - balance.abs.fdiv(borrowed)).clamp(0.0, 1.0)
  end

  # Segments for the repayment ring, in the shape the shared donut-chart
  # controller takes. Nil when the paydown cannot be computed, which is the
  # view's cue to leave the ring out rather than draw an empty one.
  def to_donut_segments
    ratio = balance_paid_ratio
    return nil if ratio.nil?

    [
      { color: "var(--color-warning)", amount: ratio, id: "paid" },
      { color: "var(--budget-unused-fill)", amount: 1 - ratio, id: "unused" }
    ]
  end

  # The same segments as JSON, which is what the shared donut-chart controller
  # reads. Mirrors Budget#to_donut_segments_json so the two ring call sites
  # hand the controller the same shape.
  def to_donut_segments_json
    to_donut_segments&.to_json
  end

  # Nil for a negative opening balance too: imports can record one, and it is
  # no amount borrowed to measure a deposit against.
  def initial_leverage_ratio
    return nil unless down_payment&.positive?

    borrowed = original_balance.amount
    return nil unless borrowed.positive?

    borrowed.fdiv(down_payment)
  end

  def leverage_band
    ratio = initial_leverage_ratio
    return nil if ratio.nil?

    LEVERAGE_BANDS.find { |_band, range| range.cover?(ratio) }&.first
  end

  # The account's opening-anchor date, memoized alongside `original_balance` so
  # one check-then-rebuild cycle reads Account's mutable state exactly once.
  def account_opening_anchor_date
    @account_opening_anchor_date ||= account.opening_anchor_date
  end

  # The contracted schedule, or nil when the loan is not amortizable
  # (upstream's AmortizationSchedule.for). Recreated when any Loan or Account
  # input changes: Account changes do not fire Loan callbacks, so the
  # signature also protects callers that hold onto a Loan instance across an
  # Account update.
  def amortization_schedule
    signature = amortization_schedule_signature
    if !defined?(@amortization_schedule) || @amortization_schedule_signature != signature
      @amortization_schedule = AmortizationSchedule.for(self)
      @amortization_schedule_signature = signature
    end
    @amortization_schedule
  end

  # Where the loan is heading from the balance on `as_of`. Not memoised:
  # `as_of` makes each call a different question, and the balance it reads
  # moves without a Loan callback.
  def payoff_projection(as_of: Date.current)
    PayoffProjection.new(self, as_of: as_of)
  end

  # A scenario's projection: the same actual-balance projection, with the
  # scenario's extra repayments applied on their own effective dates (C6).
  #
  # Unmemoized and never persisted. Scenarios are LIVE ESTIMATES -- they
  # recompute against the loan's current balance, rate and offset on every
  # view, because a scenario pinned to a stale balance cannot answer the only
  # question it is asked: given where I am now, what if?
  def payoff_projection_for_scenario(scenario, as_of: Date.current)
    PayoffProjection.new(self, scenario: scenario, as_of: as_of)
  end

  # A fresh (unmemoized) projection modeling a hypothetical extra payment on
  # top of the actual-balance projection above -- "what if I also paid an
  # extra $X each month". Purely a simulation: never touches account.balance
  # or the persisted schedule. `amount` is expected to already be validated at
  # the request boundary (see AccountsController#extra_payment_params).
  #
  # Monthly only (#304): the Extra repayments tab asks for one amount paid
  # each month, so nothing here is approximated from another cadence. `as_of`
  # lets the tab pin the same "today" on this projection and its baseline.
  def payoff_projection_with_extra(amount:, as_of: Date.current)
    extra = PayoffProjection.monthly_equivalent(amount: amount, frequency: "monthly", currency: account.currency)
    PayoffProjection.new(self, extra_payment: extra, as_of: as_of)
  end

  # The Extra repayments tab's figures (#304): this loan with an extra amount
  # paid each month, against the same loan without it, on one `as_of`.
  def extra_repayment_comparison(amount:, as_of: Date.current)
    ExtraRepaymentComparison.new(self, amount: amount, as_of: as_of)
  end

  # One annual percentage -> monthly decimal rate conversion, so the two
  # callers of the annuity formula cannot drift apart on it.
  def self.monthly_rate(annual_percentage)
    (BigDecimal(annual_percentage.to_s) / BigDecimal("100")) / BigDecimal("12")
  end

  # Whether this loan's rate can move over its life. The one place the answer
  # is defined -- callers must not compare rate_type to a string.
  def variable_rate_type?
    VARIABLE_RATE_TYPES.include?(rate_type)
  end

  # Whether a schedule can be built at all: an account, a positive original
  # balance, a positive term the simulator will walk, an interest rate, and a
  # rate type the calculator supports (AMORTIZABLE_RATE_TYPES, the one list
  # the status rake task also filters on). Subtype is NOT consulted -- a line
  # of credit carrying all of those is amortizable as far as this is concerned.
  #
  # `account` first: original_balance reads through it, and a Loan can exist
  # without one (Loan.new in a form, a fixture built in isolation).
  def amortizable?
    account.present? &&
      AMORTIZABLE_RATE_TYPES.include?(rate_type) &&
      interest_rate.present? &&
      term_months.to_i.positive? &&
      term_months.to_i <= Loan::Simulator::MAX_PERIODS &&
      original_balance.amount.positive?
  end

  # FR-204: the repayment a lender would quote TODAY.
  #
  # `AmortizationSchedule#monthly_payment` sizes the contracted payment from
  # the ORIGINAL balance at the rate effective on the FIRST payment date. For a
  # variable loan several years in, that number ignores every rate change since
  # -- which is why the Overview card once printed "N/A" for every non-fixed
  # loan rather than show it.
  #
  # For a variable loan this is the contracted schedule's payment in force
  # (#392): the schedule re-amortises the SCHEDULED balance at each recorded
  # rate change over the payments left to the original maturity, which is how a
  # lender sets the minimum. It is deliberately NOT sized on the actual balance
  # or net of an offset. Paying ahead and holding an offset lower the interest
  # and shorten the loan -- the payoff projection models both -- but neither
  # changes what the lender requires, and re-amortising the actual balance
  # quoted less than the borrower must pay. This reverses #15's "level payment
  # on the current interest-bearing balance".
  #
  # The rows come from the in-memory schedule, never the persisted rows,
  # which may be stale.
  #
  # A payment due ON `as_of` has been made, so the one in force is the next.
  # That is deliberately not AmortizationSchedule#payment_in_force, which
  # counts a payment due today as still to come.
  #
  # The maturity check comes FIRST, before the fixed-rate branch. Past maturity
  # there are no payments left, so there is no repayment to quote -- and that
  # is true of a fixed loan as much as a variable one (CodeRabbit, #79). A
  # fixed loan quotes its level repayment for every day of its term.
  def current_minimum_payment(as_of: Date.current)
    schedule = amortization_schedule
    return nil if schedule.nil?

    in_force = schedule.payments.find { |payment| payment.date > as_of }
    return nil if in_force.nil?

    return schedule.periodic_payment unless variable_rate_type?

    in_force.payment if in_force.payment.positive?
  end

  # FR-205: which scheduled payments close an accrual period carrying a new
  # rate, keyed by payment number and valued by the rate that period ends on.
  #
  # Derived from the recorded changes themselves, NOT by comparing rows'
  # rates: a change effective ON a payment date sizes that payment but is
  # charged from the following period (C10), and a change that moves and
  # reverts inside one period shows up in no row's rate at all, though the
  # borrower was charged it for part of the period (#189). The first row is
  # included: its period opens at origination, as the schedule's does.
  #
  # `payments` are the schedule's rows (AmortizationSchedule#payments). One
  # pass over the two date-ordered lists together.
  def accrual_rate_change_markers(payments)
    return {} unless variable_rate_type?
    return {} if payments.empty?

    origin = origination_date
    changes = variable_rates.select { |date, _| date >= origin && date < payments.last.date }
    return {} if changes.empty?

    next_change = 0
    payments.each_with_object({}) do |payment, markers|
      latest = nil

      while next_change < changes.length && changes[next_change].first < payment.date
        latest = changes[next_change]
        next_change += 1
      end

      markers[payment.number] = latest.last if latest
    end
  end

  # The offset accounts whose balances count against this loan: those in the
  # loan account's currency. A link in another currency is removed when either
  # side's currency changes (#328), but one stranded by any other route must
  # still never be subtracted at face value, so every reader of offset
  # balances goes through here rather than `offset_accounts`.
  def countable_offset_accounts
    return Account.none if account.nil?

    offset_accounts.where(currency: account.currency)
  end

  # Today's balance net of any linked offset, floored at zero: the balance
  # interest is actually charged on, which is what the repayment must clear.
  def interest_bearing_balance
    gross = BigDecimal(account.balance.to_s)
    offset = countable_offset_accounts.sum(:balance)
    Money.new([ gross - BigDecimal(offset.to_s), BigDecimal("0") ].max, account.currency)
  end

  # Assembles variable_rate_schedule from the form's rows.
  #
  # Deliberately a writer rather than an attr_accessor fed by a callback. The
  # column is what carries the change, and assigning only an accessor leaves
  # the record un-dirty -- Rails' autosave then skips saving the loan entirely
  # when it is updated through `accountable_attributes`, so a callback would
  # never run and the form would silently save nothing.
  #
  # Values are carried across as given rather than parsed here, so a bad date
  # or a non-numeric rate is rejected by
  # `variable_rate_schedule_entries_are_valid` with the message validation
  # already has, instead of raising mid-assembly and turning a correctable typo
  # into a 500.
  #
  # A repeated effective date resolves to the last row submitted, matching
  # `add_variable_rate_change`'s merge semantics: one date carries one rate,
  # and re-entering it replaces rather than duplicates.
  def rate_changes=(rows)
    @rate_changes = rows
    return if rows.nil?

    rows = rows.values if rows.is_a?(Hash)

    self.variable_rate_schedule = Array(rows).each_with_object({}) do |row, schedule|
      # `permit` rather than `to_unsafe_h`: the controller already filters these
      # rows, but a model that reaches past strong parameters is one refactor
      # away from accepting whatever a request sends. Naming the three fields
      # here means this method can only ever read those three.
      row = row.permit(:effective_date, :rate, :_destroy) if row.respond_to?(:permit)
      row = row.to_h.symbolize_keys

      next if ActiveModel::Type::Boolean.new.cast(row[:_destroy])

      date = row[:effective_date].to_s.strip
      rate = row[:rate]

      # A row where the user filled in neither field is not an error, it is an
      # unused row from the editor.
      next if date.blank? && rate.to_s.strip.blank?

      # ISO-8601 has more than one spelling for the same day ("2024-03-01" and
      # "20240301"), and storing both would defeat the replace-on-repeat rule
      # above: the schedule would carry two rows for one date, and which rate
      # wins in `current_variable_rate` would fall out of hash order rather
      # than out of the contract. Canonicalise what parses; keep what does not
      # exactly as entered, so validation can name it and the form can echo it
      # back to the user who typed it.
      schedule[parseable_date(date)&.iso8601 || date] = rate
    end
  end

  # Add or update a variable interest rate change on a specific date.
  def add_variable_rate_change(date, rate)
    effective_date = Date.iso8601(date.to_s)
    normalized_rate = BigDecimal(rate.to_s)
    raise ArgumentError, "rate must be a finite number" unless normalized_rate.finite?

    self.variable_rate_schedule = (variable_rate_schedule || {}).stringify_keys.merge(
      effective_date.iso8601 => rate
    )
    save!
  end

  # Recorded rate changes as [Date, BigDecimal] pairs, oldest first. The one
  # place the column is parsed for calculation: RateResolver reads these pairs
  # rather than the raw JSON, so every reader agrees on what a row means.
  # Parses each entry, so it must only be called on validated data --
  # `rate_change_rows` is the form-safe reader that tolerates what the user
  # just typed.
  def variable_rates
    (variable_rate_schedule || {})
      .map { |date, rate| [ Date.iso8601(date.to_s), BigDecimal(rate.to_s) ] }
      .sort_by(&:first)
  end

  # Rows for the form, in a shape the form can render without parsing anything.
  #
  # Deliberately not `variable_rates`: that sorts by parsing each key, so when
  # a submission fails validation and the form re-renders to show the error,
  # the invalid date the user just typed would raise inside the view -- turning
  # a correctable typo into a 500, which is the failure the assembly path was
  # written to avoid in the first place.
  #
  # Unparseable dates sort last and are echoed back as entered, so the user can
  # see and fix what they typed.
  def rate_change_rows
    (variable_rate_schedule || {}).map { |date, rate| [ date.to_s, rate ] }
      .sort_by { |date, _| [ parseable_date(date) ? 0 : 1, date ] }
  end

  # The rate in force on a given date: the latest change effective on or before
  # it, falling back to the loan's own rate before any change applies. One
  # implementation of that lookup, RateResolver's, so the Overview tab and the
  # schedule cannot disagree about which rate a date carries. A fixed loan's
  # rate is its rate, whatever rows its column retains from a variable past.
  #
  # `as_of` is injectable so a caller can pin one reference date across
  # several reads rather than letting each take its own `Date.current`.
  def current_variable_rate(as_of = Date.current)
    RateResolver.for(self).accrual_rate_for(as_of)
  end

  # What a provider should write when it reports this loan's rate on `as_of`,
  # or nil when there is nothing to write (#223). Writes nothing itself: the
  # provider's writer applies it, so locks and provenance stay with it.
  #
  # - A first sighting (no base rate yet) sets the base rate. A first reading
  #   is not evidence that anything changed, so it gets no dated row.
  # - A rate equal to the one in force on `as_of` is not a change.
  # - Otherwise the change is a row dated `as_of`; the base rate stays, since
  #   overwriting it would re-price every period before the change.
  # - A loan that is not variable gets nil: what a fixed loan does with a
  #   reported rate is the provider's decision, not a schedule question.
  #
  # Rounded to three places first because that is what the schedule stores
  # (quantize_variable_rate_schedule): comparing an unrounded reading against a
  # rounded stored rate makes an unchanged rate look changed on every sync
  # (cubic, #213).
  def variable_rate_update_for(reported_rate, as_of:)
    return nil if reported_rate.nil? || !variable_rate_type?

    rate = BigDecimal(reported_rate.to_s).round(3)
    return { interest_rate: rate } if interest_rate.blank?

    # A row already dated `as_of` is the rate in force on `as_of`, so this also
    # covers a same-day repeat; Redbark's separate same-day check could never
    # fire and was dropped when the rules moved here.
    in_force = current_variable_rate(as_of)
    return nil if in_force.present? && BigDecimal(in_force.to_s) == rate

    # A same-day row under another ISO spelling ("20260115") is replaced
    # rather than joined by a second row for the day (cubic, #400).
    day = as_of.to_date
    schedule = (variable_rate_schedule || {}).stringify_keys
      .reject { |key, _| Date.iso8601(key.to_s) == day }
    { variable_rate_schedule: schedule.merge(day.iso8601 => rate.to_s) }
  end

  # The one write for what a source OTHER than the user says about this loan:
  # Plaid, Redbark and the record-loan-rate-change rule action (#142). Returns
  # nil when the values were written or there was nothing to write, and the
  # model's error messages when it refused them. Reporting a refusal is the
  # caller's job, since only the caller knows what it was reading.
  #
  # Every write goes through Enrichable: it skips locked attributes -- a value
  # the user corrected stays corrected -- records provenance as a
  # DataEnrichment, and calls `save` rather than `save!`, so a value the model
  # refuses returns false instead of raising and taking a sync or a rule run
  # with it. Locks are ALWAYS honoured here: no caller of this has the standing
  # to override the user.
  #
  # `false` from Enrichable is NOT a refusal on its own. It also returns false
  # when every attribute was locked or already held the value, which are the
  # ordinary quiet paths; only populated `errors` mark a refusal.
  #
  # A refusal is tidied up here because Enrichable does not: it assigns, calls
  # `save`, and when `save` returns false the REJECTED VALUES are still on the
  # loan and its errors are still populated. Left there, a later write in the
  # same pass is judged against values the model would not store, and -- since
  # `enrich_attributes` returns early without saving when nothing changed --
  # finds the old errors still sitting there and reports a refusal that did not
  # happen (CodeRabbit on #213, cubic on #222). Extracted from the Redbark and
  # Plaid writers, which each carried their own copy, when the rule became a
  # third caller.
  def enrich_reporting_refusal(attrs, source:, metadata: {})
    return nil if attrs.blank?

    enrich_attributes(attrs, source: source, metadata: metadata)
    return nil if errors.empty?

    messages = errors.full_messages
    restore_attributes(attrs.keys.map(&:to_s))
    errors.clear
    messages
  end

  # This is derived rather than stored because a persisted "next" date becomes
  # stale when the current date passes it. `as_of` is the caller's "today", so
  # a response quoting several date-sensitive figures quotes them on one date.
  def next_rate_change_date(as_of: Date.current)
    return nil unless variable_rate_type?

    variable_rates.map(&:first).find { |date| date > as_of }
  end

  # Fingerprint every input used by AmortizationSchedule. It lets persisted
  # rows be invalidated when the source change happens on Account data.
  #
  # Reloads the cached account association first: this is compared against
  # by ensure_amortization_schedule_current! *before* it takes a lock (so a
  # signature match can skip the lock+query entirely -- see there), which
  # means it must reflect genuinely fresh account data on its own rather
  # than relying on with_lock's reload to have already refreshed a stale
  # cached association, the way earlier calls in the same object's lifetime
  # could otherwise silently rely on. A plain SELECT is far cheaper than the
  # lock this method exists to let callers avoid.
  def amortization_schedule_signature
    return nil unless account

    account.reload

    components = [
      LoanAmortization::ALGORITHM_VERSION,
      account.id,
      original_balance.amount.to_s,
      account.currency,
      account_opening_anchor_date.to_s,
      interest_rate.to_s,
      term_months.to_s,
      rate_type.to_s,
      start_date&.iso8601,
      variable_rates.map { |date, rate| [ date.to_s, normalized_rate(rate).to_s ] }
    ]

    # Only a convention other than the legacy actual/365 extends the
    # signature, and it is appended rather than inserted. A signature that changed for every loan would make
    # every persisted schedule stale at once: read paths (the Schedule tab, the
    # amortization_schedule API) check #schedule_current? and enqueue
    # LoanAmortizationRebuildJob when it is false (#39), so the cost is a
    # rebuild of every schedule in the estate -- up to MAX_TERM_MONTHS rows
    # each -- to produce byte-identical figures, since actual/365 is what they
    # were already calculated on. Loans that opt into another basis do get a
    # new signature, which is the rebuild that has to happen.
    components << day_count_convention unless day_count_convention == LEGACY_DAY_COUNT_CONVENTION

    Digest::SHA256.hexdigest(components.to_json)
  end

  # The contracted schedule's rows in the shape the persisted cache stores and
  # the API serves (#184 phase 4e): upstream's Payment rows plus the two
  # figures the cache has always carried beside them. `beginning_balance` is
  # the balance the period opened on -- the previous row's ending balance, or
  # the principal -- and `interest_rate` the annual rate in force when the
  # period opened, which is the rate Loan::Simulator records on its row: a
  # change part-way through a period shows on the row after it.
  def amortization_rows
    schedule = amortization_schedule
    return [] if schedule.nil?

    resolver = RateResolver.for(self)
    opening_balance = schedule.principal
    period_start = schedule.start_date

    schedule.payments.map do |payment|
      row = {
        payment_number: payment.number,
        payment_date: payment.date,
        payment_amount: payment.payment.amount,
        principal_payment: payment.principal.amount,
        interest_payment: payment.interest.amount,
        beginning_balance: opening_balance,
        ending_balance: payment.ending_balance.amount,
        interest_rate: BigDecimal(resolver.accrual_rate_for(period_start).to_s)
      }
      opening_balance = payment.ending_balance.amount
      period_start = payment.date
      row
    end
  end

  # Rebuild the persisted amortization schedule under a loan lock so readers
  # never observe a delete/insert gap and concurrent rebuilds serialize.
  def rebuild_amortization_schedule
    with_lock { rebuild_amortization_schedule_locked! }
  end

  # Lazily build or replace the persisted schedule when it is missing or stale.
  # This also removes rows when a loan is no longer amortizable.
  #
  # Two layers avoid taking the row lock on the common "nothing to do" path,
  # which matters because this is called from read paths (Schedule tab,
  # amortization_schedule API) as well as writes:
  #   1. Memoized by signature on this in-memory Loan instance -- repeat
  #      calls against the same instance (e.g. a controller ensuring the
  #      schedule, then building a projection that ensures it again) skip
  #      everything below once the schedule is known current for this
  #      signature.
  #   2. A lock-free #schedule_current? check (standard double-checked
  #      locking): only acquire with_lock when that check says a rebuild
  #      might be needed. It's re-verified with the same logic once the lock
  #      is held (below), so a false "not current" from a lock-free read
  #      racing a concurrent writer just costs a redundant lock+no-op --
  #      never an incorrect rebuild.
  # A genuinely stale schedule (interest_rate/term/etc. actually changed)
  # still gets a fresh signature and is rebuilt normally. Callers that must
  # not write on a read should use #schedule_current? instead.
  def ensure_amortization_schedule_current!
    # Clear memoized account-derived values before computing the lock-free
    # signature so an external Account update cannot be hidden by this Loan's
    # cached balance or opening date.
    clear_amortization_schedule_cache!
    signature = amortization_schedule_signature
    return if @amortization_schedule_ensured_signature == signature
    return if schedule_current_for_signature?(signature)

    with_lock do
      clear_amortization_schedule_cache!

      unless amortizable?
        amortizations.delete_all if amortizations.exists?
        reset_amortizations_association!
        @amortization_schedule_ensured_signature = signature
        next
      end

      rebuild_amortization_schedule_locked! unless schedule_current_for_signature?(signature)
      @amortization_schedule_ensured_signature = signature
    end
  end

  # Read-only freshness check. `rebuild_amortization_schedule_locked!` always
  # replaces every row for a loan in one transaction under the same
  # signature, so the persisted set is current if and only if a row exists
  # with today's signature -- no need to regenerate the schedule just to
  # count it. Backed by the existing loan_id+schedule_signature index.
  def schedule_current?
    return false unless amortizable?
    amortizations.exists?(schedule_signature: amortization_schedule_signature)
  end

  private

    # Whether the persisted amortizations already match `signature`, with no
    # writes and (on the caller's part) no lock. Used both as the lock-free
    # fast path above and, called again, as the authoritative check once
    # with_lock is held -- same logic either way, just a live query against
    # amortizations either time, never a cached read.
    def schedule_current_for_signature?(signature)
      return !amortizations.exists? unless amortizable?

      row_count = amortization_schedule.payments.length
      matching_rows = amortizations.where(schedule_signature: signature).count
      matching_rows == row_count && amortizations.count == row_count
    end

    # Rewrites the persisted schedule inside the caller's row lock. Deletes the
    # rows outright when the loan is no longer amortizable, so a type change
    # cannot leave a stale schedule behind that still renders.
    def rebuild_amortization_schedule_locked!
      clear_amortization_schedule_cache!

      unless amortizable?
        amortizations.delete_all if amortizations.exists?
        reset_amortizations_association!
        return
      end

      signature = amortization_schedule_signature
      now = Time.current
      rows = amortization_rows.map do |row|
        row.merge(
          loan_id: id,
          schedule_signature: signature,
          algorithm_version: LoanAmortization::ALGORITHM_VERSION,
          generated_at: now,
          created_at: now,
          updated_at: now
        )
      end

      transaction do
        amortizations.delete_all
        LoanAmortization.insert_all!(rows) if rows.any?
      end
      reset_amortizations_association!
    end

    # The Loan columns a schedule is computed from. Account-side inputs (the
    # balance, the opening anchor) are deliberately absent: they do not fire
    # Loan callbacks, and the signature covers them instead. `initial_balance`
    # joined the list when #original_balance started preferring it (#184).
    def amortization_inputs_changed?
      saved_change_to_initial_balance? ||
        saved_change_to_interest_rate? ||
        saved_change_to_term_months? ||
        saved_change_to_rate_type? ||
        saved_change_to_start_date? ||
        saved_change_to_day_count_convention? ||
        saved_change_to_variable_rate_schedule?
    end

    # Enqueues instead of rebuilding inline: a rebuild allocates and inserts
    # up to MAX_TERM_MONTHS rows under a row lock, which shouldn't happen
    # synchronously inside an ordinary save. Deduped per loan via
    # sidekiq-unique-jobs, so a burst of saves collapses to one rebuild.
    def enqueue_amortization_rebuild
      LoanAmortizationRebuildJob.perform_later(id)
    end

    # A Date, or nil for anything unparseable. Nil rather than an exception
    # because the callers are a form reader and a key canonicaliser, both of
    # which must survive whatever the user typed.
    def parseable_date(value)
      Date.iso8601(value.to_s)
    rescue ArgumentError, TypeError
      nil
    end

    # Whether this save carried the offset attribute at all. `nil` means "not
    # about offsets"; an empty array means "remove them all" -- conflating the
    # two would silently unlink every offset on an unrelated edit.
    def offset_account_ids_supplied?
      !offset_account_ids.nil?
    end


    # Also syncs on a rate-type change, because BECOMING fixed is what makes a
    # loan's offset links meaningless -- `sync_offset_accounts` clears them for
    # any non-variable type.
    def offset_accounts_need_sync?
      offset_account_ids_supplied? || saved_change_to_rate_type?
    end

    # Reconciles the join rows to the submitted set.
    def sync_offset_accounts
      # An absent virtual attribute means "this save was not about offsets" --
      # a rate-type-only edit, say -- NOT "remove them all". Reading it as the
      # latter deleted every link on a variable -> adjustable transition, which
      # is the one transition #14 exists to make safe. Only reproducible on a
      # freshly loaded record: an instance that set offset_account_ids earlier
      # still carries them, which is why the first test written for this
      # passed.
      ids = if !variable_rate_type?
        []
      elsif offset_account_ids_supplied?
        offset_account_ids_for_sync.map(&:id)
      else
        loan_offset_accounts.pluck(:account_id)
      end

      loan_offset_accounts.where.not(account_id: ids).delete_all
      ids.each do |account_id|
        loan_offset_accounts.find_or_create_by!(account_id:)
      end
    end

    # Rejects unknown or ineligible offset accounts, so the form can show the
    # reason rather than the database raising at the user. Runs as a validation
    # so `save` actually returns false -- see the registration note above.
    def collateral_account_is_eligible
      collateral_problems.each { |problem| errors.add(:collateral_account, problem) }
    end

    # The collateral link answers to the same viewers as an offset link: a link
    # the loan's viewers could not follow would show them a figure from an account
    # they cannot see.
    def collateral_viewers(loan_account)
      Loan.viewers_of(loan_account)
    end

    def validate_offset_accounts
      return unless variable_rate_type?

      ids = normalized_offset_account_ids
      accounts = offset_account_ids_for_sync
      missing_ids = ids - accounts.map { |account| account.id.to_s }
      errors.add(:offset_account_ids, "contains an unknown account") if missing_ids.any?

      accounts.each do |account|
        # Reuse the EXISTING join row when there is one, rather than building a
        # fresh unsaved link. `LoanOffsetAccount` validates account_id unique
        # within loan_id, and a new record cannot see that the row it collides
        # with is the very link being kept -- so re-submitting an offset the
        # loan already has failed its own uniqueness rule. A persisted record
        # excludes itself from that check.
        #
        # Harmless while this ran on `before_save`, where the error was
        # recorded and ignored. Once it became a real validation it rejected
        # every ordinary edit of a variable loan that has offsets, because
        # `LoansController#set_offset_accounts` pre-populates the form with the
        # existing ids (CodeRabbit, #87).
        link = loan_offset_accounts.find_by(account_id: account.id) ||
          LoanOffsetAccount.new(loan: self, account:)
        next if link.valid?

        errors.add(:offset_account_ids, link.errors.full_messages.to_sentence)
      end
    end

    # Loads the submitted accounts. Called separately by validation and by the
    # after-save sync -- two queries, not a shared snapshot -- so in principle
    # they could see different rows if an account were deleted between them.
    def offset_account_ids_for_sync
      Account.where(id: normalized_offset_account_ids).to_a
    end

    # Form input arrives with blanks and duplicates and as mixed types; this is
    # the one place that is tidied, so every reader sees the same shape.
    def normalized_offset_account_ids
      Array(offset_account_ids).reject(&:blank?).map(&:to_s).uniq
    end

    # Rates are money-adjacent, so they are compared and compounded as
    # BigDecimal. Raises rather than coercing: a non-numeric rate here would
    # otherwise become 0.0 and quietly produce an interest-free loan.
    def normalized_rate(rate)
      BigDecimal(rate.to_s)
    rescue ArgumentError, TypeError
      raise ArgumentError, "variable interest rates must be numeric"
    end

    # Rounds stored rates to three decimals, matching the column's precision, so
    # a value does not display differently from the one used in calculation.
    # Unparseable values pass through untouched for validation to report.
    def quantize_variable_rate_schedule
      return unless variable_rate_schedule.is_a?(Hash)

      self.variable_rate_schedule = variable_rate_schedule.transform_values do |rate|
        begin
          BigDecimal(rate.to_s).round(3).to_f
        rescue ArgumentError, TypeError
          rate
        end
      end
    end

    # The share of one instalment each part takes, for a progress bar.
    def payment_ratios(principal, interest, premium, total)
      return { principal: 0.0, interest: 0.0, insurance: 0.0 } unless total.amount.positive?

      whole = total.amount.to_f

      {
        principal: principal.amount.to_f / whole,
        interest: interest.amount.to_f / whole,
        insurance: premium.amount.to_f / whole
      }
    end

    # Drops every per-instance memo derived from the schedule's inputs. Kept in
    # one place so a new memo cannot be added and forgotten here.
    def clear_amortization_schedule_cache!
      @amortization_schedule = nil
      @amortization_schedule_signature = nil
      @original_balance = nil
      @account_opening_anchor_date = nil
    end

    # Forces the association to reload after a bulk insert or delete, which
    # bypasses the association and would otherwise leave it holding stale rows.
    def reset_amortizations_association!
      association(:amortizations).reset
    end

    # Guards the jsonb column's shape at the model layer -- dates parseable,
    # rates numeric and in range -- so the calculation can read it without
    # defending against malformed entries on every access.
    def variable_rate_schedule_entries_are_valid
      return if variable_rate_schedule.blank?

      unless variable_rate_schedule.is_a?(Hash)
        errors.add(:variable_rate_schedule, "must be a JSON object")
        return
      end

      variable_rate_schedule.each do |date, rate|
        begin
          Date.iso8601(date.to_s)
        rescue ArgumentError
          errors.add(:variable_rate_schedule, "contains an invalid effective date")
        end

        begin
          parsed_rate = BigDecimal(rate.to_s)
          if !parsed_rate.finite?
            errors.add(:variable_rate_schedule, "contains a non-numeric rate")
          elsif parsed_rate.negative? || parsed_rate > 100
            errors.add(:variable_rate_schedule, "contains a rate outside the supported 0-100 range")
          end
        rescue ArgumentError, TypeError
          errors.add(:variable_rate_schedule, "contains a non-numeric rate")
        end
      end
    end

    class << self
      # The Accountable presentation trio. Every accountable type answers these
      # so the UI can render an account without knowing which type it is.
      def color
        "#D444F1"
      end

      # Lucide icon name, resolved through the `icon` helper.
      def icon
        "hand-coins"
      end

      # Loans are liabilities: they subtract from net worth rather than adding.
      def classification
        "liability"
      end
    end
end
