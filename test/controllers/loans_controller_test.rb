require "test_helper"

class LoansControllerTest < ActionDispatch::IntegrationTest
  OFFSET_SELECT = "account[accountable_attributes][offset_account_ids][]".freeze

  include AccountableResourceInterfaceTest

  setup do
    sign_in @user = users(:family_admin)
    @account = accounts(:loan)
  end

  test "updates the day-count basis" do
    patch loan_path(@account), params: {
      account: {
        accountable_attributes: {
          id: @account.accountable_id,
          day_count_convention: "actual_actual"
        }
      }
    }

    assert_equal "actual_actual", @account.accountable.reload.day_count_convention
  end

  # --- #14 ------------------------------------------------------------------

  test "updates the origination date and enqueues a rebuild" do
    assert_enqueued_with job: LoanAmortizationRebuildJob do
      patch loan_path(@account), params: {
        account: { accountable_attributes: { id: @account.accountable_id, start_date: "2023-04-01" } }
      }
    end

    assert_equal Date.new(2023, 4, 1), @account.accountable.reload.start_date
  end

  test "assembles submitted rate-change rows into the schedule and enqueues a rebuild" do
    @account.accountable.update!(rate_type: "variable")

    assert_enqueued_with job: LoanAmortizationRebuildJob do
      patch loan_path(@account), params: {
        account: {
          accountable_attributes: {
            id: @account.accountable_id,
            rate_changes: [
              { effective_date: "2024-03-01", rate: "4.5" },
              { effective_date: "2024-06-01", rate: "6.0" }
            ]
          }
        }
      }
    end

    assert_equal({ "2024-03-01" => 4.5, "2024-06-01" => 6.0 },
      @account.accountable.reload.variable_rate_schedule)
  end

  # The jsonb column must not be reachable by mass assignment: permitting it
  # would let a request write arbitrary JSON into a column the calculation
  # reads (R13). Submitting it directly must be ignored, not honoured.
  test "a directly submitted variable_rate_schedule is not mass-assignable" do
    @account.accountable.update!(rate_type: "variable")

    patch loan_path(@account), params: {
      account: {
        accountable_attributes: {
          id: @account.accountable_id,
          variable_rate_schedule: { "2024-03-01" => "99.9" }
        }
      }
    }

    # The update must SUCCEED with the parameter ignored, not fail because of
    # it: asserting only the empty schedule would also pass if the request had
    # been rejected outright, which is a different behaviour.
    assert_redirected_to @account
    assert_empty @account.accountable.reload.variable_rate_schedule.to_h,
      "the jsonb column must only be writable through assembled rate_changes rows"
  end

  test "an invalid rate-change row re-renders with an inline error rather than raising" do
    @account.accountable.update!(rate_type: "variable")

    patch loan_path(@account), params: {
      account: {
        accountable_attributes: {
          id: @account.accountable_id,
          rate_changes: [ { effective_date: "not-a-date", rate: "4.5" } ]
        }
      }
    }

    assert_response :unprocessable_entity
    assert_empty @account.accountable.reload.variable_rate_schedule.to_h

    # The re-rendered row must show what was typed. A date input blanks a value
    # it cannot parse, so echoing an invalid date into type="date" leaves the
    # user an empty box beside an error about a value they can no longer see.
    assert_select "input[name=?][type=text][value=?]",
      "account[accountable_attributes][rate_changes][][effective_date]", "not-a-date"
  end

  # cubic, #77: two ISO-8601 spellings of one day must not become two rows --
  # the schedule would carry a duplicate the replace-on-repeat rule is supposed
  # to prevent, and which rate wins would fall out of hash order.
  test "equivalent spellings of one effective date collapse to a single row" do
    @account.accountable.update!(rate_type: "variable")

    patch loan_path(@account), params: {
      account: {
        accountable_attributes: {
          id: @account.accountable_id,
          rate_changes: [
            { effective_date: "2024-03-01", rate: "4.5" },
            { effective_date: "20240301", rate: "6.0" }
          ]
        }
      }
    }

    assert_equal({ "2024-03-01" => 6.0 }, @account.accountable.reload.variable_rate_schedule)
  end

  test "creates with loan details" do
    assert_difference -> { Account.count } => 1,
      -> { Loan.count } => 1,
      -> { Valuation.count } => 1,
      -> { Entry.count } => 1 do
      post loans_path, params: {
        account: {
          name: "New Loan",
          balance: 50000,
          currency: "USD",
          institution_name: "Local Bank",
          institution_domain: "localbank.example",
          notes: "Mortgage notes",
          accountable_type: "Loan",
          accountable_attributes: {
            subtype: "mortgage",
            interest_rate: 5.5,
            term_months: 60,
            rate_type: "fixed",
            initial_balance: 50000
          }
        }
      }
    end

    created_account = Account.order(:created_at).last

    assert_equal "New Loan", created_account.name
    assert_equal 50000, created_account.balance
    assert_equal "USD", created_account.currency
    assert_equal "Local Bank", created_account[:institution_name]
    assert_equal "localbank.example", created_account[:institution_domain]
    assert_equal "Mortgage notes", created_account[:notes]
    assert_equal "mortgage", created_account.accountable.subtype
    assert_equal 5.5, created_account.accountable.interest_rate
    assert_equal 60, created_account.accountable.term_months
    assert_equal "fixed", created_account.accountable.rate_type
    assert_equal 50000, created_account.accountable.initial_balance

    assert_redirected_to created_account
    assert_equal "Loan account created", flash[:notice]
    assert_enqueued_with(job: SyncJob)
  end

  test "updates with loan details" do
    assert_no_difference [ "Account.count", "Loan.count" ] do
      patch loan_path(@account), params: {
        account: {
          name: "Updated Loan",
          balance: 45000,
          currency: "USD",
          institution_name: "Updated Bank",
          institution_domain: "updatedbank.example",
          notes: "Updated loan notes",
          accountable_type: "Loan",
          accountable_attributes: {
            id: @account.accountable_id,
            subtype: "auto",
            interest_rate: 4.5,
            term_months: 48,
            rate_type: "fixed",
            initial_balance: 48000
          }
        }
      }
    end

    @account.reload

    assert_equal "Updated Loan", @account.name
    assert_equal 45000, @account.balance
    assert_equal "Updated Bank", @account[:institution_name]
    assert_equal "updatedbank.example", @account[:institution_domain]
    assert_equal "Updated loan notes", @account[:notes]
    assert_equal "auto", @account.accountable.subtype
    assert_equal 4.5, @account.accountable.interest_rate
    assert_equal 48, @account.accountable.term_months
    assert_equal "fixed", @account.accountable.rate_type
    assert_equal 48000, @account.accountable.initial_balance

    assert_redirected_to @account
    assert_equal "Loan account updated", flash[:notice]
    assert_enqueued_with(job: SyncJob)
  end

  test "creates a variable loan with visible offset accounts" do
    offset = @account.family.accounts.create!(
      name: "New offset", balance: 12_500, currency: @account.currency, accountable: Depository.new
    )
    # Visible to the whole family, as the new loan will be: a family that shares
    # by default shares the loan with everyone (#290).
    offset.auto_share_with_family!

    assert_difference -> { Account.where(accountable_type: "Loan").count }, 1 do
      post loans_path, params: { account: variable_loan_params(currency: @account.currency, offset_ids: [ offset.id ]) }
    end

    created_loan = Account.where(accountable_type: "Loan").order(:created_at).last.accountable

    assert_equal "variable", created_loan.rate_type
    assert_equal [ offset.id ], created_loan.offset_accounts.pluck(:id)
    assert_redirected_to created_loan.account
  end

  # --- #290: offsets submitted with a new loan --------------------------------

  test "refuses a new loan whose offset is in another currency" do
    euro = @account.family.accounts.create!(
      name: "Euro offset", balance: 12_500, currency: "EUR", accountable: Depository.new
    )
    euro.auto_share_with_family!
    assert_not_equal "EUR", @account.currency, "precondition"

    assert_no_difference [ -> { Account.count }, -> { LoanOffsetAccount.count } ] do
      post loans_path, params: { account: variable_loan_params(currency: @account.currency, offset_ids: [ euro.id ]) }
    end

    assert_response :unprocessable_entity
    assert_match "must use the same currency as the loan", response.body
  end

  test "refuses a new loan whose offset the rest of the family cannot see" do
    private_offset = @account.family.accounts.create!(
      name: "Private offset", balance: 12_500, currency: @account.currency, accountable: Depository.new
    )
    assert @account.family.share_all_by_default?, "precondition"
    assert_empty private_offset.account_shares, "precondition"

    assert_no_difference [ -> { Account.count }, -> { LoanOffsetAccount.count } ] do
      post loans_path, params: { account: variable_loan_params(currency: @account.currency, offset_ids: [ private_offset.id ]) }
    end

    assert_response :unprocessable_entity
    assert_match "must be visible to every loan viewer", response.body
  end

  # --- #129 collateral link --------------------------------------------------

  test "links a loan to a property" do
    property = accounts(:property)

    assert_nil @account.loan.collateral_account_id

    patch loan_path(@account), params: {
      account: { accountable_attributes: { id: @account.accountable_id, collateral_account_id: property.id } }
    }

    assert_redirected_to @account
    assert_equal property.id, @account.loan.reload.collateral_account_id
  end

  test "an unknown collateral id is refused, not a server error, and the link is kept" do
    property = accounts(:property)
    @account.loan.update!(collateral_account: property)

    patch loan_path(@account), params: {
      account: { accountable_attributes: { id: @account.accountable_id, collateral_account_id: SecureRandom.uuid } }
    }

    assert_response :unprocessable_entity
    assert_equal property.id, @account.loan.reload.collateral_account_id
  end

  # The loan's own validation used to read the persisted account, so a request
  # that changes the currency and the asset together was judged on the old one.
  test "changing the currency and the collateral in one request is judged on the new currency" do
    euro_property = @account.family.accounts.create!(
      name: "Flat in Lisbon", currency: "EUR", balance: 300_000, owner: @user, accountable: Property.new
    )
    euro_property.auto_share_with_family!

    patch loan_path(@account), params: {
      account: { currency: "EUR", accountable_attributes: { id: @account.accountable_id, collateral_account_id: euro_property.id } }
    }

    assert_redirected_to @account
    assert_equal "EUR", @account.reload.currency
    assert_equal euro_property.id, @account.loan.collateral_account_id
  end

  test "changing the currency away from the collateral's in the same request is refused" do
    property = accounts(:property)

    patch loan_path(@account), params: {
      account: { currency: "EUR", accountable_attributes: { id: @account.accountable_id, collateral_account_id: property.id } }
    }

    assert_response :unprocessable_entity
    assert_equal "USD", @account.reload.currency
    assert_nil @account.loan.collateral_account_id
  end

  test "a blank collateral clears the link" do
    @account.loan.update!(collateral_account: accounts(:property))

    patch loan_path(@account), params: {
      account: { accountable_attributes: { id: @account.accountable_id, collateral_account_id: "" } }
    }

    assert_nil @account.loan.reload.collateral_account_id
  end

  # Each refusal is checked against an EXISTING link: with none to begin with, a
  # rejected update that quietly cleared the link would look the same.
  test "refuses an account from another family and leaves the link as it was" do
    kept = accounts(:property)
    @account.loan.update!(collateral_account: kept)
    foreign = families(:empty).accounts.create!(name: "Not ours", currency: "USD", balance: 1, accountable: Property.new)

    patch loan_path(@account), params: {
      account: { accountable_attributes: { id: @account.accountable_id, collateral_account_id: foreign.id } }
    }

    assert_response :unprocessable_entity
    assert_equal kept.id, @account.loan.reload.collateral_account_id
  end

  test "refuses a kind of account that cannot secure a loan and leaves the link as it was" do
    kept = accounts(:vehicle)
    @account.loan.update!(collateral_account: kept)

    patch loan_path(@account), params: {
      account: { accountable_attributes: { id: @account.accountable_id, collateral_account_id: accounts(:depository).id } }
    }

    assert_response :unprocessable_entity
    assert_equal kept.id, @account.loan.reload.collateral_account_id
  end

  test "a failed create re-renders the form with the collateral choices" do
    foreign = families(:empty).accounts.create!(name: "Not ours", currency: "USD", balance: 1, accountable: Property.new)

    post loans_path, params: {
      account: {
        name: "Secured loan", balance: 50_000, currency: "USD", accountable_type: "Loan",
        accountable_attributes: { subtype: "mortgage", interest_rate: 5, term_months: 60, rate_type: "fixed",
                                  initial_balance: 50_000, collateral_account_id: foreign.id }
      }
    }

    assert_response :unprocessable_entity
    assert_select "select[name='account[accountable_attributes][collateral_account_id]']" do
      assert_select "option[value='#{accounts(:property).id}']", text: accounts(:property).name
      assert_select "option[value='#{accounts(:vehicle).id}']", text: accounts(:vehicle).name
      assert_select "option[value='#{foreign.id}']", count: 0
    end
  end

  # The currency is on the same form, so the first render cannot filter by it; once
  # a submission has named one, the re-rendered picker can.
  test "a failed create offers only assets in the currency it was submitted with" do
    euro = @account.family.accounts.create!(name: "Flat in Lisbon", currency: "EUR", balance: 1, owner: @user, accountable: Property.new)
    foreign = families(:empty).accounts.create!(name: "Not ours", currency: "USD", balance: 1, accountable: Property.new)

    post loans_path, params: {
      account: {
        name: "Secured loan", balance: 50_000, currency: "USD", accountable_type: "Loan",
        accountable_attributes: { subtype: "mortgage", interest_rate: 5, term_months: 60, rate_type: "fixed",
                                  initial_balance: 50_000, collateral_account_id: foreign.id }
      }
    }

    assert_response :unprocessable_entity
    assert_select "option[value='#{accounts(:property).id}']"
    assert_select "option[value='#{euro.id}']", count: 0
  end

  test "creates a loan secured by a vehicle" do
    vehicle = accounts(:vehicle)
    vehicle.auto_share_with_family!

    post loans_path, params: {
      account: {
        name: "Car loan", balance: 12_000, currency: "USD", accountable_type: "Loan",
        accountable_attributes: { subtype: "auto", interest_rate: 6, term_months: 48, rate_type: "fixed",
                                  initial_balance: 12_000, collateral_account_id: vehicle.id }
      }
    }

    created = Account.order(:created_at).last.accountable
    assert_equal vehicle.id, created.collateral_account_id
  end

  test "the form offers properties and vehicles the save would accept, and nothing else" do
    foreign = families(:empty).accounts.create!(name: "Not ours", currency: "USD", balance: 1, accountable: Property.new)
    euro = @account.family.accounts.create!(name: "Flat in Lisbon", currency: "EUR", balance: 1, owner: @user, accountable: Property.new)

    get edit_loan_path(@account)

    assert_response :success
    assert_select "select[name='account[accountable_attributes][collateral_account_id]']" do
      assert_select "option[value='']"
      assert_select "option[value='#{accounts(:property).id}']", text: accounts(:property).name
      assert_select "option[value='#{accounts(:vehicle).id}']", text: accounts(:vehicle).name
      assert_select "option[value='#{accounts(:depository).id}']", count: 0
      assert_select "option[value='#{foreign.id}']", count: 0
      assert_select "option[value='#{euro.id}']", count: 0
    end
  end

  # Open the form, change nothing, save: the link must survive even though the
  # asset would no longer be accepted fresh.
  test "an existing link stays selectable when the asset would no longer qualify" do
    property = accounts(:property)
    @account.loan.update!(collateral_account: property)
    property.update_columns(currency: "EUR")

    get edit_loan_path(@account)

    assert_select "option[value='#{property.id}'][selected]"

    patch loan_path(@account), params: {
      account: { accountable_attributes: { id: @account.accountable_id, collateral_account_id: property.id, interest_rate: 4.2 } }
    }

    assert_redirected_to @account
    assert_equal property.id, @account.loan.reload.collateral_account_id
  end

  test "a viewer who cannot see the asset leaves the link alone when they save" do
    property = accounts(:property)
    @account.loan.update!(collateral_account: property)
    member = users(:family_member)
    @account.share_with!(member, permission: "full_control")
    @account.update!(owner: @user)
    sign_in member

    assert_not Account.accessible_by(member).exists?(id: property.id), "precondition"

    patch loan_path(@account), params: {
      account: { accountable_attributes: { id: @account.accountable_id, collateral_account_id: "", interest_rate: 4.1 } }
    }

    loan = @account.loan.reload
    assert_equal property.id, loan.collateral_account_id
    assert_equal 4.1, loan.interest_rate
  end

  test "the loan page shows the equity in its collateral" do
    accounts(:property).update_columns(balance: 550_000)
    @account.update_columns(balance: 500_000)
    @account.loan.update!(collateral_account: accounts(:property))

    get account_path(@account)

    assert_response :success
    assert_select "[data-collateral-position]" do
      assert_select "h3", text: "Secured by"
      assert_select "a[href='#{account_path(accounts(:property))}']", text: accounts(:property).name
      assert_select "h4", text: "Equity"
      assert_select "p", text: "$50,000.00"
    end
  end

  test "a switched-off loan shows no collateral section, not the asset's full value as equity" do
    @account.loan.update!(collateral_account: accounts(:property))
    @account.update_columns(status: "disabled")

    get account_path(@account)

    assert_response :success
    assert_select "[data-collateral-position]", count: 0
  end

  test "a loan with no collateral shows no collateral section" do
    get account_path(@account)

    assert_response :success
    assert_select "[data-collateral-position]", count: 0
  end

  # `adjustable` moved from this list to the one below when #14 gave it the
  # variable meaning. It is a behaviour change, not a test fix: an adjustable
  # loan's offset links used to be deleted on every save.
  test "removes submitted offset accounts when changing to a fixed rate" do
    offset = @account.family.accounts.create!(
      name: "Existing offset", balance: 12_500, currency: @account.currency, accountable: Depository.new
    )
    loan = @account.accountable
    loan.update!(rate_type: "variable", offset_account_ids: [ offset.id ])
    assert_equal [ offset.id ], loan.reload.offset_accounts.pluck(:id)

    patch loan_path(@account), params: {
      account: {
        accountable_type: "Loan",
        accountable_attributes: {
          id: loan.id,
          rate_type: "fixed",
          offset_account_ids: [ offset.id ]
        }
      }
    }

    assert_empty loan.reload.offset_accounts
  end

  test "keeps offset accounts across every rate type whose rate can move" do
    offset = @account.family.accounts.create!(
      name: "Existing offset", balance: 12_500, currency: @account.currency, accountable: Depository.new
    )
    loan = @account.accountable

    # Named explicitly, not iterated from Loan::VARIABLE_RATE_TYPES: a test that
    # reads the constant it is meant to pin passes whatever the constant says,
    # and shrinking the constant back was exactly the mutation this must catch.
    %w[variable adjustable].each do |rate_type|
      loan.update!(rate_type: "fixed", offset_account_ids: [])

      patch loan_path(@account), params: {
        account: {
          accountable_type: "Loan",
          accountable_attributes: {
            id: loan.id,
            rate_type:,
            offset_account_ids: [ offset.id ]
          }
        }
      }

      assert_equal [ offset.id ], loan.reload.offset_accounts.pluck(:id),
        "a #{rate_type} loan must keep the offset accounts submitted with it"
    end
  end

  # --- #319: an edit that changes only the offsets ---------------------------
  #
  # `offset_account_ids` is not a column, so a nested save that set nothing else
  # left the loan unchanged and Rails' autosave skipped validating and saving it:
  # the request redirected with the success notice and no link moved.

  test "an edit that changes only the offsets links the offset" do
    loan = @account.accountable
    loan.update!(rate_type: "variable")
    offset = shared_offset(balance: 12_500)
    assert_empty loan.reload.offset_accounts, "precondition"
    before = loan.interest_bearing_balance

    assert_difference -> { loan.loan_offset_accounts.count }, 1 do
      patch loan_path(@account), params: offset_only_params(loan, [ "", offset.id ])
    end

    assert_redirected_to @account
    assert_equal [ offset.id ], loan.reload.offset_accounts.pluck(:id)
    assert_equal Money.new(12_500, @account.currency), before - loan.interest_bearing_balance
  end

  test "an edit that submits an empty offset list removes the offset" do
    loan = @account.accountable
    offset = shared_offset
    loan.update!(rate_type: "variable", offset_account_ids: [ offset.id ])
    assert_equal [ offset.id ], loan.reload.offset_accounts.pluck(:id), "precondition"

    assert_difference -> { loan.loan_offset_accounts.count }, -1 do
      patch loan_path(@account), params: offset_only_params(loan, [ "" ])
    end

    assert_redirected_to @account
    assert_empty loan.reload.offset_accounts
  end

  test "an ineligible offset submitted alone is refused, not reported as saved" do
    loan = @account.accountable
    loan.update!(rate_type: "variable")
    euro = @account.family.accounts.create!(
      name: "Euro offset", balance: 12_500, currency: "EUR", accountable: Depository.new
    )
    euro.auto_share_with_family!
    assert_not_equal "EUR", @account.currency, "precondition"

    assert_no_difference -> { LoanOffsetAccount.count } do
      patch loan_path(@account), params: offset_only_params(loan, [ "", euro.id ])
    end

    assert_response :unprocessable_entity
    assert_match "must use the same currency as the loan", response.body
  end

  # The controller pre-fills the loan's existing ids when the request carries no
  # offset key, so with the fix this edit validates and re-syncs the links. It
  # must keep the same join row, not drop or recreate it.
  test "an edit with no offset key leaves the links as they were" do
    loan = @account.accountable
    offset = shared_offset
    loan.update!(rate_type: "variable", offset_account_ids: [ offset.id ])
    link_ids = loan.loan_offset_accounts.pluck(:id)
    assert_equal 1, link_ids.size, "precondition"

    patch loan_path(@account), params: { account: { name: "Renamed mortgage" } }

    assert_redirected_to @account
    assert_equal "Renamed mortgage", @account.reload.name
    assert_equal link_ids, loan.reload.loan_offset_accounts.pluck(:id)
  end

  # Known limitation, tracked in #329 and kept out of #319's scope by the owner:
  # the form's multiple select has `include_hidden: false`, so deselecting every
  # offset submits no offset key, and the controller pre-fills the existing ids.
  # The last offset therefore cannot be removed from the form. This pins today's
  # behaviour so #329's form change has to update it deliberately.
  test "deselecting every offset in the edit form keeps the links (#329)" do
    loan = @account.accountable
    offset = shared_offset
    loan.update!(rate_type: "variable", offset_account_ids: [ offset.id ])
    link_ids = loan.loan_offset_accounts.pluck(:id)

    get edit_loan_path(@account)
    assert_response :success
    assert_select "select[name=?][multiple]", "account[accountable_attributes][offset_account_ids][]"
    assert_select "input[type=hidden][name=?]", "account[accountable_attributes][offset_account_ids][]", count: 0,
      message: "with no hidden blank, a deselect-all submits no offset key"

    patch loan_path(@account), params: {
      account: { accountable_attributes: { id: loan.id, rate_type: loan.rate_type } }
    }

    assert_redirected_to @account
    assert_equal link_ids, loan.reload.loan_offset_accounts.pluck(:id)
  end

  # Completes #290's boundary case, which #317 could only test with another loan
  # column changing in the same request.
  test "a currency change that resubmits the offsets and changes no loan column is judged on the new currency" do
    loan = @account.accountable
    offset = shared_offset
    loan.update!(rate_type: "variable", offset_account_ids: [ offset.id ])

    patch loan_path(@account), params: {
      account: { currency: "EUR", accountable_attributes: { id: loan.id, offset_account_ids: [ "", offset.id ] } }
    }

    assert_response :unprocessable_entity
    assert_match "must use the same currency as the loan", response.body
    assert_equal "USD", @account.reload.currency
    assert_equal [ offset.id ], loan.reload.offset_accounts.pluck(:id)
  end

  # #328: moving the offset into another currency from its own edit form used
  # to keep the link, and every later save of the loan form then failed on it.
  test "an offset moved to another currency is unlinked, and the loan form saves again" do
    loan = @account.loan
    offset = shared_offset(balance: 1_000)
    loan.update!(rate_type: "variable", offset_account_ids: [ offset.id ])

    patch depository_path(offset), params: { account: { currency: "EUR" } }
    assert_equal "EUR", offset.reload.currency
    assert_empty loan.reload.offset_accounts

    patch loan_path(@account), params: { account: { name: "Renamed mortgage" } }
    assert_redirected_to @account
    assert_equal "Renamed mortgage", @account.reload.name
  end

  # The views ask whether the loan has an offset; a stranded link is not one.
  test "the loan page does not present a stranded offset as an offset" do
    loan = @account.loan
    offset = shared_offset(balance: 1_000)
    loan.update!(rate_type: "variable", offset_account_ids: [ offset.id ])

    get account_url(@account, tab: "overview")
    assert_response :success
    assert_includes response.body, "Variable + offset", "precondition: a matching offset is presented"
    get account_url(@account, tab: "schedule")
    assert_response :success
    assert_includes response.body, "linked offset balance", "precondition: a matching offset is presented"

    offset.update_columns(currency: "EUR")

    # A crashed tab renders an error page without either phrase, so the
    # absence below means something only on a page that rendered.
    get account_url(@account, tab: "overview")
    assert_response :success
    assert_not_includes response.body, "Variable + offset"
    get account_url(@account, tab: "schedule")
    assert_response :success
    assert_not_includes response.body, "linked offset balance"
  end

  # --- #325: the new-loan form offers offsets ---------------------------------

  test "the new-loan form lists a same-currency asset shared with the family" do
    offset = shared_offset

    get new_loan_path

    assert_response :success
    assert_select "select[name=?] option[value=?]", OFFSET_SELECT, offset.id
  end

  test "the new-loan form leaves out what the save would refuse" do
    assert @account.family.share_all_by_default?, "precondition"
    private_offset = @account.family.accounts.create!(
      name: "Private offset", balance: 100, currency: @account.currency, owner: @user, accountable: Depository.new
    )
    euro = @account.family.accounts.create!(
      name: "Euro offset", balance: 100, currency: "EUR", accountable: Depository.new
    ).tap(&:auto_share_with_family!)
    other_family = families(:empty).accounts.create!(
      name: "Other family offset", balance: 100, currency: @account.currency, accountable: Depository.new
    )

    get new_loan_path

    assert_response :success
    assert_select "select[name=?] option[value=?]", OFFSET_SELECT, private_offset.id, count: 0
    assert_select "select[name=?] option[value=?]", OFFSET_SELECT, euro.id, count: 0
    assert_select "select[name=?] option[value=?]", OFFSET_SELECT, accounts(:credit_card).id, count: 0
    assert_select "select[name=?] option[value=?]", OFFSET_SELECT, other_family.id, count: 0
  end

  test "the new-loan form lists the owner's private asset when the family does not share by default" do
    @account.family.update!(default_account_sharing: "private")
    private_offset = @account.family.accounts.create!(
      name: "Private offset", balance: 100, currency: @account.currency, owner: @user, accountable: Depository.new
    )

    get new_loan_path

    assert_select "select[name=?] option[value=?]", OFFSET_SELECT, private_offset.id
  end

  test "the new-loan form lists offsets in the submitted currency" do
    usd = shared_offset
    euro = @account.family.accounts.create!(
      name: "Euro offset", balance: 100, currency: "EUR", accountable: Depository.new
    ).tap(&:auto_share_with_family!)

    get new_loan_path, params: { account: { currency: "EUR" } }

    assert_select "select[name=?] option[value=?]", OFFSET_SELECT, euro.id
    assert_select "select[name=?] option[value=?]", OFFSET_SELECT, usd.id, count: 0
  end

  test "a failed create re-renders with the offsets listed" do
    offset = shared_offset
    params = variable_loan_params(currency: @account.currency, offset_ids: [ offset.id ])
    params[:accountable_attributes][:interest_rate] = -1

    assert_no_difference -> { Account.where(accountable_type: "Loan").count } do
      post loans_path, params: { account: params }
    end

    assert_response :unprocessable_entity
    assert_select "select[name=?] option[value=?]", OFFSET_SELECT, offset.id
  end

  test "every account the new-loan form offers is one the save accepts" do
    offered = shared_offset

    get new_loan_path
    assert_select "select[name=?] option[value=?]", OFFSET_SELECT, offered.id

    post loans_path, params: { account: variable_loan_params(currency: @account.currency, offset_ids: [ offered.id ]) }

    created = Account.where(accountable_type: "Loan").order(:created_at).last.accountable
    assert_equal [ offered.id ], created.offset_accounts.pluck(:id)
  end

  test "the edit form lists the same offsets as before" do
    offset = shared_offset
    expected = LoanOffsetAccount.eligible_accounts_for(@account.loan, viewer: @user).map(&:id)
    assert_includes expected, offset.id, "precondition"

    get edit_loan_path(@account)

    expected.each { |id| assert_select "select[name=?] option[value=?]", OFFSET_SELECT, id }
    assert_select "select[name='#{OFFSET_SELECT}'] option", count: expected.size
  end

  private
    def shared_offset(balance: 0)
      @account.family.accounts.create!(
        name: "Offset", balance: balance, currency: @account.currency, accountable: Depository.new
      ).tap(&:auto_share_with_family!)
    end

    # What the edit form sends when only the offset select changed: the loan's
    # id and its unchanged rate type, and no other loan field.
    def offset_only_params(loan, offset_ids)
      { account: { accountable_attributes: { id: loan.id, rate_type: loan.rate_type, offset_account_ids: offset_ids } } }
    end

    def variable_loan_params(currency:, offset_ids:)
      {
        name: "Variable Loan",
        balance: 50_000,
        currency: currency,
        accountable_type: "Loan",
        accountable_attributes: {
          subtype: "mortgage",
          interest_rate: 5.5,
          term_months: 60,
          rate_type: "variable",
          initial_balance: 50_000,
          offset_account_ids: offset_ids
        }
      }
    end
end
