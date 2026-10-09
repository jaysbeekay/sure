require "test_helper"

class LoanTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  test "rejects invalid subtype" do
    loan = Loan.new(subtype: "invalid")

    assert_not loan.valid?
    assert_includes loan.errors[:subtype], "is not included in the list"
  end

  # --- #14: structured rate-change rows assembled into the jsonb column ------
  #
  # The column is not mass-assignable on purpose (R13), so the form submits
  # rows and the model assembles. These cover what the assembly has to get
  # right; the values themselves are judged by the existing
  # variable_rate_schedule validation.

  test "rate_changes rows are assembled into the variable rate schedule" do
    loan = Loan.new(subtype: "mortgage", rate_type: "variable", interest_rate: 5, term_months: 12)
    loan.rate_changes = [
      { effective_date: "2024-03-01", rate: "4.5" },
      { effective_date: "2024-06-01", rate: "6.0" }
    ]

    assert loan.valid?
    # Values arrive as strings from the form and are normalised to numbers by
    # quantize_variable_rate_schedule, which runs after assembly by design.
    assert_equal({ "2024-03-01" => 4.5, "2024-06-01" => 6.0 }, loan.variable_rate_schedule)
  end

  test "a repeated effective date replaces rather than duplicating" do
    loan = Loan.new(subtype: "mortgage", rate_type: "variable", interest_rate: 5, term_months: 12)
    loan.rate_changes = [
      { effective_date: "2024-03-01", rate: "4.5" },
      { effective_date: "2024-03-01", rate: "7.25" }
    ]

    assert loan.valid?
    # One date carries one rate, matching add_variable_rate_change's merge
    # semantics -- the later row wins rather than the schedule holding two
    # entries the calculation would have to choose between.
    assert_equal({ "2024-03-01" => 7.25 }, loan.variable_rate_schedule)
  end

  test "a row marked for removal is dropped, and a wholly blank row is ignored" do
    loan = Loan.new(subtype: "mortgage", rate_type: "variable", interest_rate: 5, term_months: 12)
    loan.rate_changes = [
      { effective_date: "2024-03-01", rate: "4.5" },
      { effective_date: "2024-06-01", rate: "6.0", _destroy: "1" },
      { effective_date: "", rate: "" }
    ]

    assert loan.valid?
    assert_equal({ "2024-03-01" => 4.5 }, loan.variable_rate_schedule)
  end

  # A typo must come back as a correctable field error. Parsing during assembly
  # would raise instead, turning a wrong date into a 500.
  test "an invalid row is rejected by validation rather than raising" do
    loan = Loan.new(subtype: "mortgage", rate_type: "variable", interest_rate: 5, term_months: 12)
    loan.rate_changes = [ { effective_date: "not-a-date", rate: "4.5" } ]

    assert_nothing_raised { loan.valid? }
    assert_not loan.valid?
    assert_includes loan.errors[:variable_rate_schedule].to_sentence, "invalid effective date"
  end

  test "a rate outside the supported range is rejected" do
    loan = Loan.new(subtype: "mortgage", rate_type: "variable", interest_rate: 5, term_months: 12)
    loan.rate_changes = [ { effective_date: "2024-03-01", rate: "150" } ]

    assert_not loan.valid?
    assert_includes loan.errors[:variable_rate_schedule].to_sentence, "0-100"
  end

  # Not supplying the rows at all must leave an existing schedule alone --
  # otherwise saving any other attribute would silently wipe the rate history.
  test "omitting rate_changes leaves an existing schedule untouched" do
    loan = Loan.create!(subtype: "mortgage", rate_type: "variable", interest_rate: 5, term_months: 12,
                        variable_rate_schedule: { "2024-03-01" => "4.5" })

    loan.update!(term_months: 24)

    assert_equal({ "2024-03-01" => 4.5 }, loan.reload.variable_rate_schedule)
  end

  test "rejects an unsupported day-count convention" do
    loan = Loan.new(day_count_convention: "thirty_360")

    assert_not loan.valid?
    assert_includes loan.errors[:day_count_convention], "is not included in the list"
  end

  test "defaults to the actual/365 day-count convention" do
    assert_equal "actual_365", Loan.new.day_count_convention
  end

  # The signature gates a rebuild that runs on READ paths, so a loan left on
  # the default basis must hash exactly as it did before the attribute existed
  # -- otherwise deploying this rebuilds every persisted schedule on first view
  # to produce identical figures.
  test "the default day-count convention leaves the schedule signature untouched" do
    loan_account = Account.create! \
      family: families(:dylan_family),
      name: "Mortgage Loan",
      balance: 500000,
      currency: "USD",
      accountable: Loan.create!(
        subtype: "mortgage",
        interest_rate: 3.5,
        term_months: 360,
        rate_type: "fixed"
      )

    loan = loan_account.loan
    legacy_signature = Digest::SHA256.hexdigest([
      Loan::AmortizationSchedule::ALGORITHM_VERSION,
      loan.account.id,
      loan.original_balance.amount.to_s,
      loan.account.currency,
      loan.account_opening_anchor_date.to_s,
      loan.interest_rate.to_s,
      loan.term_months.to_s,
      loan.rate_type.to_s,
      loan.start_date&.iso8601,
      loan.variable_rates.map { |date, rate| [ date.to_s, loan.send(:normalized_rate, rate).to_s ] }
    ].to_json)

    assert_equal "actual_365", loan.day_count_convention
    assert_equal legacy_signature, loan.send(:amortization_schedule_signature),
      "a loan on the default basis must keep the signature it had before the attribute existed"

    loan.update!(day_count_convention: "actual_actual")
    assert_not_equal legacy_signature, loan.send(:amortization_schedule_signature)

    loan.update!(day_count_convention: "actual_365")
    assert_equal legacy_signature, loan.send(:amortization_schedule_signature),
      "returning to the default must return the loan to its original schedule identity"
  end

  test "changing the day-count convention rebuilds the amortization schedule" do
    loan_account = Account.create! \
      family: families(:dylan_family),
      name: "Mortgage Loan",
      balance: 500000,
      currency: "USD",
      accountable: Loan.create!(
        subtype: "mortgage",
        interest_rate: 3.5,
        term_months: 360,
        rate_type: "fixed"
      )

    loan = loan_account.loan
    before = loan.send(:amortization_schedule_signature)

    assert_enqueued_with(job: LoanAmortizationRebuildJob, args: [ loan.id ]) do
      loan.update!(day_count_convention: "actual_actual")
    end

    assert_not_equal before, loan.send(:amortization_schedule_signature),
      "the convention must be part of the schedule signature, or a change would serve a stale schedule"
  end

  test "rejects malformed variable rate schedule entries" do
    loan = Loan.new(variable_rate_schedule: { "not-a-date" => "not-a-rate" })

    assert_not loan.valid?
    assert_includes loan.errors[:variable_rate_schedule], "contains an invalid effective date"
    assert_includes loan.errors[:variable_rate_schedule], "contains a non-numeric rate"
  end

  test "rejects a variable rate schedule entry outside the supported range" do
    loan = Loan.new(variable_rate_schedule: { "2027-01-01" => -1, "2028-01-01" => 250 })

    assert_not loan.valid?
    assert_includes loan.errors[:variable_rate_schedule], "contains a rate outside the supported 0-100 range"
  end

  test "quantizes variable rate schedule entries to 3 decimal places" do
    loan = Loan.new(rate_type: "variable", variable_rate_schedule: { "2027-01-01" => 5.123456 })
    assert loan.valid?
    assert_equal 5.123, loan.variable_rate_schedule["2027-01-01"]
  end

  test "rejects term months outside the supported range" do
    loan = Loan.new(term_months: 0)
    assert_not loan.valid?
    assert_includes loan.errors[:term_months], "must be greater than 0"

    loan = Loan.new(term_months: Loan::MAX_TERM_MONTHS + 1)
    assert_not loan.valid?
    assert_includes loan.errors[:term_months], "must be less than or equal to #{Loan::MAX_TERM_MONTHS}"
  end

  test "rejects an interest rate outside the supported range" do
    loan = Loan.new(interest_rate: -1)
    assert_not loan.valid?
    assert_includes loan.errors[:interest_rate], "must be greater than or equal to 0"

    loan = Loan.new(interest_rate: 101)
    assert_not loan.valid?
    assert_includes loan.errors[:interest_rate], "must be less than or equal to 100"
  end

  test "calculates correct monthly payment for fixed rate loan" do
    loan_account = Account.create! \
      family: families(:dylan_family),
      name: "Mortgage Loan",
      balance: 500000,
      currency: "USD",
      accountable: Loan.create!(
        subtype: "mortgage",
        interest_rate: 3.5,
        term_months: 360,
        rate_type: "fixed"
      )

    assert_equal BigDecimal("2245.22"), loan_account.loan.monthly_payment.amount
  end

  test "amortization_schedule returns valid schedule for fixed rate loan" do
    loan_account = Account.create! \
      family: families(:dylan_family),
      name: "Mortgage Loan",
      balance: 500000,
      currency: "USD",
      accountable: Loan.create!(
        subtype: "mortgage",
        interest_rate: 3.5,
        term_months: 360,
        rate_type: "fixed"
      )

    schedule = loan_account.loan.amortization_schedule
    assert schedule.amortizable?
    assert_equal 360, schedule.payment_count
    assert schedule.payoff_date.present?
    assert schedule.total_interest.positive?
    assert schedule.monthly_payment.positive?
  end

  test "amortization_schedule is amortizable for variable rate loan with a base rate" do
    loan_account = Account.create! \
      family: families(:dylan_family),
      name: "Variable Rate Loan",
      balance: 500000,
      currency: "USD",
      accountable: Loan.create!(
        subtype: "line_of_credit",
        interest_rate: 3.5,
        term_months: 360,
        rate_type: "variable"
      )

    schedule = loan_account.loan.amortization_schedule
    assert schedule.amortizable?
  end

  test "amortization_schedule not amortizable for loan without an interest rate" do
    loan_account = Account.create! \
      family: families(:dylan_family),
      name: "No Rate Loan",
      balance: 500000,
      currency: "USD",
      accountable: Loan.create!(
        subtype: "other",
        interest_rate: nil,
        term_months: 360,
        rate_type: "fixed"
      )

    schedule = loan_account.loan.amortization_schedule
    assert_not schedule.amortizable?
  end

  test "amortizable? is false before the loan has an account" do
    loan = Loan.create!(
      subtype: "mortgage",
      interest_rate: 3.5,
      term_months: 360,
      rate_type: "fixed"
    )

    assert_nil loan.account
    assert_not loan.amortizable?
    assert_equal 0, loan.amortizations.count
  end

  test "an amortization rebuild is enqueued (not run inline) when terms change" do
    loan_account = Account.create! \
      family: families(:dylan_family),
      name: "Mortgage Loan",
      balance: 500000,
      currency: "USD",
      accountable: Loan.create!(
        subtype: "mortgage",
        interest_rate: 3.5,
        term_months: 360,
        rate_type: "fixed"
      )

    loan = loan_account.loan
    assert_equal 0, loan.amortizations.count

    assert_enqueued_with(job: LoanAmortizationRebuildJob, args: [ loan.id ]) do
      loan.update!(interest_rate: 4.0)
    end
    assert_equal 0, loan.amortizations.count, "the save itself must not synchronously build the schedule"

    perform_enqueued_jobs
    assert_equal 360, loan.amortizations.count
  end

  test "clears the persisted schedule when a loan becomes non-amortizable" do
    loan_account = Account.create! \
      family: families(:dylan_family),
      name: "Mortgage Loan",
      balance: 500000,
      currency: "USD",
      accountable: Loan.create!(
        subtype: "mortgage",
        interest_rate: 3.5,
        term_months: 360,
        rate_type: "fixed"
      )

    loan = loan_account.loan
    loan.rebuild_amortization_schedule
    assert_equal 360, loan.amortizations.count

    perform_enqueued_jobs do
      loan.update!(interest_rate: nil)
    end

    assert_equal 0, loan.amortizations.count
  end

  test "rebuilds the persisted schedule when Account-derived inputs change" do
    loan_account = Account.create! \
      family: families(:dylan_family),
      name: "Mortgage Loan",
      balance: 500000,
      currency: "USD",
      accountable: Loan.create!(
        subtype: "mortgage",
        interest_rate: 3.5,
        term_months: 360,
        rate_type: "fixed"
      )

    loan = loan_account.loan
    loan.ensure_amortization_schedule_current!
    assert_equal 360, loan.amortizations.count
    original_signature = loan.amortizations.ordered.first.schedule_signature

    loan_account.update!(balance: 450000)
    loan.ensure_amortization_schedule_current!

    assert_not_equal original_signature, loan.amortizations.ordered.first.schedule_signature
    assert_equal BigDecimal("450000"), loan.amortizations.ordered.first.beginning_balance
  end

  test "ensure_amortization_schedule_current! does not duplicate rows when called repeatedly" do
    loan_account = Account.create! \
      family: families(:dylan_family),
      name: "Mortgage Loan",
      balance: 500000,
      currency: "USD",
      accountable: Loan.create!(
        subtype: "mortgage",
        interest_rate: 3.5,
        term_months: 360,
        rate_type: "fixed"
      )

    loan = loan_account.loan
    assert_equal 0, loan.amortizations.count

    3.times { loan.ensure_amortization_schedule_current! }

    assert_equal 360, loan.amortizations.count
  end

  test "ensure_amortization_schedule_current! serializes the check-then-rebuild through a row lock" do
    loan_account = Account.create! \
      family: families(:dylan_family),
      name: "Mortgage Loan",
      balance: 500000,
      currency: "USD",
      accountable: Loan.create!(
        subtype: "mortgage",
        interest_rate: 3.5,
        term_months: 360,
        rate_type: "fixed"
      )

    loan = loan_account.loan
    loan.expects(:with_lock).once.yields
    loan.ensure_amortization_schedule_current!
  end

  test "adds variable rate changes" do
    loan_account = Account.create! \
      family: families(:dylan_family),
      name: "Variable Rate Loan",
      balance: 500000,
      currency: "USD",
      accountable: Loan.create!(
        subtype: "line_of_credit",
        interest_rate: 3.5,
        term_months: 360,
        rate_type: "variable"
      )

    loan = loan_account.loan
    loan.add_variable_rate_change(Date.new(2027, 1, 1), 4.0)
    loan.add_variable_rate_change(Date.new(2028, 1, 1), 4.5)

    assert_equal 2, loan.variable_rates.length
    assert_equal 4.0, loan.variable_rates[0][1]
    assert_equal 4.5, loan.variable_rates[1][1]
    # Inside travel_to: next_rate_change_date compares against Date.current, so
    # asserting a hard-coded 2027 date against the real clock is a test that
    # starts failing on 2027-01-01 for no reason connected to the code.
    travel_to Date.new(2026, 1, 1) do
      assert_equal Date.new(2027, 1, 1), loan.next_rate_change_date
    end

    travel_to Date.new(2027, 1, 2) do
      assert_equal Date.new(2028, 1, 1), loan.next_rate_change_date
    end

    travel_to Date.new(2028, 1, 2) do
      assert_nil loan.next_rate_change_date
    end
  end

  test "gets current variable rate based on date" do
    loan_account = Account.create! \
      family: families(:dylan_family),
      name: "Variable Rate Loan",
      balance: 500000,
      currency: "USD",
      accountable: Loan.create!(
        subtype: "line_of_credit",
        interest_rate: 3.5,
        term_months: 360,
        rate_type: "variable",
        variable_rate_schedule: {
          "2024-01-01" => 3.5,
          "2026-01-01" => 4.0,
          "2027-01-01" => 4.5
        }
      )

    loan = loan_account.loan
    assert_equal 3.5, loan.current_variable_rate(Date.new(2024, 6, 1))
    assert_equal 4.0, loan.current_variable_rate(Date.new(2026, 6, 1))
    assert_equal 4.5, loan.current_variable_rate(Date.new(2027, 6, 1))
  end

  test "payoff_projection returns a memoized PayoffProjection for the loan" do
    loan_account = Account.create! \
      family: families(:dylan_family),
      name: "Mortgage Loan",
      balance: 500000,
      currency: "USD",
      accountable: Loan.create!(
        subtype: "mortgage",
        interest_rate: 3.5,
        term_months: 360,
        rate_type: "fixed",
        start_date: Date.current
      )

    loan = loan_account.loan
    assert_instance_of Loan::PayoffProjection, loan.payoff_projection
    assert_same loan.payoff_projection, loan.payoff_projection
  end

  test "payoff_projection_with_extra returns a fresh projection boosted by the given amount" do
    loan = build_chart_loan(balance: 500000)

    with_extra = loan.payoff_projection_with_extra(amount: "100")

    assert_not_same loan.payoff_projection, with_extra
    assert_equal loan.payoff_projection.monthly_payment + Money.new(100, "USD"), with_extra.monthly_payment
  end

  # cubic, #78: a rate-type-only edit must not take the offset links with it.
  #
  # Asserted on a FRESHLY LOADED record on purpose. The first version of this
  # test reused the instance that had just set offset_account_ids, so the
  # virtual attribute was still populated and the deletion never happened --
  # a green test over a live defect. A real request always loads the loan
  # fresh, which is the case that mattered.
  test "moving between two variable rate types without submitting offsets keeps them" do
    family = families(:dylan_family)
    loan = family.accounts.create!(
      name: "Offset Retention Loan", balance: 250_000, currency: "USD",
      accountable: Loan.new(rate_type: "variable", interest_rate: 5, term_months: 240)
    ).loan
    offset = family.accounts.create!(
      name: "Retention Offset", balance: 10_000, currency: "USD", accountable: Depository.new
    )
    loan.update!(offset_account_ids: [ offset.id ])
    assert_equal [ offset.id ], Loan.find(loan.id).offset_accounts.pluck(:id)

    Loan.find(loan.id).update!(rate_type: "adjustable")

    assert_equal [ offset.id ], Loan.find(loan.id).offset_accounts.pluck(:id),
      "a rate-type-only edit submits no offset ids; that must not be read as 'remove them all'"
  end

  test "moving to a fixed rate without submitting offsets still removes them" do
    family = families(:dylan_family)
    loan = family.accounts.create!(
      name: "Offset Removal Loan", balance: 250_000, currency: "USD",
      accountable: Loan.new(rate_type: "variable", interest_rate: 5, term_months: 240)
    ).loan
    offset = family.accounts.create!(
      name: "Removal Offset", balance: 10_000, currency: "USD", accountable: Depository.new
    )
    loan.update!(offset_account_ids: [ offset.id ])

    Loan.find(loan.id).update!(rate_type: "fixed")

    assert_empty Loan.find(loan.id).offset_accounts,
      "a fixed-rate loan has no offset, so the links must go"
  end

  # CodeRabbit, #86: `validate_offset_accounts` was registered with
  # `before_save`, where `errors.add` does not stop the write -- only
  # `throw :abort` does. An unknown id therefore saved cleanly, and
  # `sync_offset_accounts` then persisted only the accounts it could load, so
  # the user was told the edit succeeded while the link silently did not exist.
  test "an unknown offset account id fails the save instead of being dropped" do
    family = families(:dylan_family)
    loan = family.accounts.create!(
      name: "Unknown Offset Loan", balance: 250_000, currency: "USD",
      accountable: Loan.new(rate_type: "variable", interest_rate: 5, term_months: 240)
    ).loan

    assert_no_difference "LoanOffsetAccount.count" do
      refute loan.update(offset_account_ids: [ SecureRandom.uuid ]),
        "an unknown offset account id must make the save fail, not succeed silently"
    end

    assert_includes loan.errors[:offset_account_ids], "contains an unknown account"
    assert_empty Loan.find(loan.id).offset_accounts
  end

  # An account that EXISTS but is ineligible already failed the save before this
  # change -- measured, not assumed: under `before_save` this same case returned
  # false and created no link, because the after-save sync cannot persist a link
  # LoanOffsetAccount refuses. Only a genuinely unknown id slipped through, which
  # is why the test above is the one that goes red without the fix. Kept as a
  # characterisation test so moving the callback does not quietly regress it.
  test "an ineligible offset account fails the save instead of being dropped" do
    family = families(:dylan_family)
    loan = family.accounts.create!(
      name: "Ineligible Offset Loan", balance: 250_000, currency: "USD",
      accountable: Loan.new(rate_type: "variable", interest_rate: 5, term_months: 240)
    ).loan
    wrong_currency = family.accounts.create!(
      name: "Ineligible Offset", balance: 10_000, currency: "EUR", accountable: Depository.new
    )

    assert_no_difference "LoanOffsetAccount.count" do
      refute loan.update(offset_account_ids: [ wrong_currency.id ]),
        "an offset account in another currency must make the save fail"
    end

    assert_predicate loan.errors[:offset_account_ids], :any?
    assert_empty Loan.find(loan.id).offset_accounts
  end

  # CodeRabbit, #87: the first draft of this fix broke every ordinary edit of a
  # variable loan that already had an offset. `validate_offset_accounts` built a
  # fresh `LoanOffsetAccount` for each submitted account, and a NEW record
  # cannot exclude itself from the account_id-unique-within-loan_id rule, so the
  # link being KEPT collided with its own existing row. Harmless while this ran
  # on `before_save` and the error was ignored; fatal once it became a real
  # validation, because the form pre-populates the existing ids.
  test "re-submitting an offset account the loan already has does not fail the save" do
    family = families(:dylan_family)
    loan = family.accounts.create!(
      name: "Retained Offset Loan", balance: 250_000, currency: "USD",
      accountable: Loan.new(rate_type: "variable", interest_rate: 5, term_months: 240)
    ).loan
    offset = family.accounts.create!(
      name: "Retained Offset", balance: 10_000, currency: "USD", accountable: Depository.new
    )
    loan.update!(offset_account_ids: [ offset.id ])

    fresh = Loan.find(loan.id)
    assert fresh.update(offset_account_ids: [ offset.id ], interest_rate: 6),
      "keeping an existing offset must not collide with its own join row"

    reloaded = Loan.find(loan.id)
    assert_equal [ offset.id ], reloaded.offset_accounts.pluck(:id)
    assert_equal 6, reloaded.interest_rate.to_i,
      "the unrelated edit in the same save must not be rolled back"
  end

  # Guards the other direction: making this a validation must not stop a
  # legitimate offset edit from going through.
  test "a valid offset account still saves and links" do
    family = families(:dylan_family)
    loan = family.accounts.create!(
      name: "Valid Offset Loan", balance: 250_000, currency: "USD",
      accountable: Loan.new(rate_type: "variable", interest_rate: 5, term_months: 240)
    ).loan
    offset = family.accounts.create!(
      name: "Valid Offset", balance: 10_000, currency: "USD", accountable: Depository.new
    )

    assert loan.update(offset_account_ids: [ offset.id ])
    assert_equal [ offset.id ], Loan.find(loan.id).offset_accounts.pluck(:id)
  end

  # #223. The dated-rate rules, shared by every provider that reports a
  # variable rate. The loan only answers what should be written; the provider
  # writes it, so locks and provenance stay with the provider's writer.
  test "variable_rate_update_for sets the base rate on a first sighting" do
    loan = Loan.new(rate_type: "variable", interest_rate: nil)

    assert_equal({ interest_rate: BigDecimal("5.2") },
                 loan.variable_rate_update_for(5.2, as_of: Date.new(2026, 1, 15)))
  end

  test "variable_rate_update_for dates a moved rate to as_of, not today" do
    loan = Loan.new(rate_type: "variable", interest_rate: 4.5)

    update = loan.variable_rate_update_for(5.2, as_of: Date.new(2026, 1, 15))

    assert_equal({ "2026-01-15" => "5.2" }, update[:variable_rate_schedule])
    assert_not update.key?(:interest_rate), "the base rate must not move"
  end

  test "variable_rate_update_for keeps the rows already on the schedule" do
    loan = Loan.new(rate_type: "variable", interest_rate: 4.5,
                    variable_rate_schedule: { "2025-06-01" => 4.8 })

    update = loan.variable_rate_update_for(5.2, as_of: Date.new(2026, 1, 15))

    assert_equal %w[2025-06-01 2026-01-15], update[:variable_rate_schedule].keys.sort
  end

  test "variable_rate_update_for records nothing when the rate in force is unchanged" do
    loan = Loan.new(rate_type: "variable", interest_rate: 4.5,
                    variable_rate_schedule: { "2025-06-01" => 5.125 })

    # A four-decimal reading of the three-decimal stored rate is not a change.
    assert_nil loan.variable_rate_update_for(BigDecimal("5.1249"), as_of: Date.new(2026, 1, 15))
  end

  test "variable_rate_update_for records nothing when today's row already holds the rate" do
    loan = Loan.new(rate_type: "variable", interest_rate: 4.5,
                    variable_rate_schedule: { "2026-01-15" => 5.2 })

    assert_nil loan.variable_rate_update_for(5.2, as_of: Date.new(2026, 1, 15))
  end

  test "variable_rate_update_for leaves a fixed loan to its caller" do
    loan = Loan.new(rate_type: "fixed", interest_rate: 4.5)

    assert_nil loan.variable_rate_update_for(5.2, as_of: Date.new(2026, 1, 15))
  end

  private
    def build_chart_loan(balance:, interest_rate: 3.5, term_months: 360, start_date: Date.current, rate_type: "fixed")
      account = Account.create! \
        family: families(:dylan_family),
        name: "Chart Loan #{SecureRandom.hex(4)}",
        balance: balance,
        currency: "USD",
        accountable: Loan.create!(
          subtype: "mortgage",
          interest_rate: interest_rate,
          term_months: term_months,
          rate_type: rate_type,
          start_date: start_date
        )

      account.entries.create!(
        name: "Starting balance",
        amount: balance,
        currency: "USD",
        date: start_date,
        entryable: Valuation.new(kind: "opening_anchor")
      )

      # Amortization rebuilds happen asynchronously (after_save enqueues
      # LoanAmortizationRebuildJob rather than rebuilding inline) -- build the
      # persisted schedule synchronously here so tests read current rows
      # without needing perform_enqueued_jobs.
      account.loan.tap(&:rebuild_amortization_schedule)
    end
end
