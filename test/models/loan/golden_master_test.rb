require "test_helper"
require "json"

# Phase 0 of #184: what the fork's loan engine produces TODAY, recorded before
# any of the reconciliation onto upstream's engine begins.
#
# Each scenario's figures -- every schedule row, the projection, the current
# minimum payment and the figure the retirement planner seeds from -- are
# stored in test/fixtures/files/loan_golden_master/<scenario>.json. Later
# phases run against the same files: a figure that moves fails here, and the
# failure names the scenario and the first path that changed, so every
# movement is either zero or named and explained in its PR.
#
# Regenerate only deliberately, when a phase is meant to move a figure:
#   LOAN_GOLDEN_MASTER_WRITE=1 bin/rails test test/models/loan/golden_master_test.rb
# and explain every changed line in that PR.
class Loan::GoldenMasterTest < ActiveSupport::TestCase
  AS_OF = Date.new(2027, 1, 15)
  DIRECTORY = Rails.root.join("test/fixtures/files/loan_golden_master")

  SCENARIOS = {
    "fixed" => { start_date: Date.new(2024, 1, 15) },
    "variable_change_on_payment_date" => { start_date: Date.new(2024, 1, 15), rate_type: "variable",
                                           variable_rate_schedule: { "2025-03-15" => "7.5" } },
    "variable_change_mid_period" => { start_date: Date.new(2024, 1, 15), rate_type: "variable",
                                      variable_rate_schedule: { "2025-03-02" => "7.5", "2026-06-20" => "5.25" } },
    "offset" => { start_date: Date.new(2024, 1, 15), rate_type: "variable", offset_balance: 50_000 },
    "actual_actual" => { start_date: Date.new(2024, 1, 15), day_count_convention: "actual_actual" },
    "leap_february_start" => { start_date: Date.new(2024, 2, 29) },
    "month_end_start" => { start_date: Date.new(2024, 1, 31) },
    "matured" => { start_date: Date.new(2024, 1, 15), term_months: 12, balance: 0 },
    "initial_balance_differs_from_first_valuation" => { start_date: Date.new(2024, 1, 15), initial_balance: 320_000 }
  }.freeze

  setup do
    @family = families(:dylan_family)
  end

  SCENARIOS.each do |name, options|
    test "the fork engine's figures for #{name.tr('_', ' ')} are unchanged" do
      travel_to AS_OF do
        figures = capture(build_loan(**options))
        path = DIRECTORY.join("#{name}.json")

        if ENV["LOAN_GOLDEN_MASTER_WRITE"]
          FileUtils.mkdir_p(DIRECTORY)
          File.write(path, JSON.pretty_generate(figures) + "\n")
          skip "wrote #{path.relative_path_from(Rails.root)}"
        end

        assert File.exist?(path), "no golden master recorded for #{name}"
        expected = JSON.parse(File.read(path))
        assert_equal expected, JSON.parse(JSON.generate(figures)),
                     "#{name} moved; first difference at #{first_difference(expected, JSON.parse(JSON.generate(figures)))}"
      end
    end
  end

  private
    def build_loan(start_date:, rate_type: "fixed", interest_rate: 6, term_months: 360, balance: 285_000,
                   variable_rate_schedule: {}, day_count_convention: "actual_365", initial_balance: nil, offset_balance: nil)
      loan = Loan.new(rate_type: rate_type, interest_rate: interest_rate, term_months: term_months,
                      start_date: start_date, variable_rate_schedule: variable_rate_schedule,
                      initial_balance: initial_balance)
      loan.day_count_convention = day_count_convention if day_count_convention

      account = @family.accounts.create!(name: "Golden master #{SecureRandom.hex(4)}", balance: balance,
                                         currency: "USD", accountable: loan)
      account.entries.create!(date: start_date, name: "Opening balance", amount: 300_000, currency: "USD",
                              entryable: Valuation.new(kind: "opening_anchor"))

      if offset_balance
        offset = @family.accounts.create!(name: "Offset #{SecureRandom.hex(4)}", balance: offset_balance,
                                          currency: "USD", accountable: Depository.new)
        account.loan.update!(offset_account_ids: [ offset.id ])
      end

      Loan.find(account.loan.id)
    end

    def capture(loan)
      schedule = loan.amortization_schedule
      projection = loan.payoff_projection

      {
        "schedule" => {
          "monthly_payment" => scalar(schedule.monthly_payment),
          "total_interest" => scalar(schedule.total_interest),
          "payoff_date" => scalar(schedule.payoff_date),
          "rows" => schedule.payments.map { |row| canonical(row) }
        },
        "projection" => {
          "applicable" => projection.applicable?,
          "monthly_payment" => scalar(projection.monthly_payment),
          "payoff_date" => scalar(projection.payoff_date),
          "total_interest" => scalar(projection.total_interest),
          "converged" => projection.converged?,
          "rows" => projection.payments.map { |row| canonical(row) }
        },
        "current_minimum_payment" => scalar(loan.current_minimum_payment(as_of: AS_OF)),
        # RetirementPlan#seed_loans reads exactly this figure for a loan it seeds.
        "planner_seed_monthly_payment" => scalar(projection.monthly_payment)
      }
    end

    def canonical(row)
      row.to_h.sort_by { |key, _| key.to_s }.to_h { |key, value| [ key.to_s, scalar(value) ] }
    end

    def scalar(value)
      case value
      when nil then nil
      when BigDecimal then value.to_s("F")
      when Money then "#{value.amount.to_s("F")} #{value.currency.iso_code}"
      when Date then value.iso8601
      when Numeric, true, false then value
      else value.to_s
      end
    end

    def first_difference(expected, actual, path = "$")
      return path if expected.class != actual.class

      case expected
      when Hash
        (expected.keys | actual.keys).each do |key|
          found = first_difference(expected[key], actual[key], "#{path}.#{key}")
          return found if found
        end
        nil
      when Array
        return "#{path} (length #{expected.length} -> #{actual.length})" if expected.length != actual.length

        expected.each_with_index do |item, index|
          found = first_difference(item, actual[index], "#{path}[#{index}]")
          return found if found
        end
        nil
      else
        expected == actual ? nil : "#{path} (#{expected.inspect} -> #{actual.inspect})"
      end
    end
end
