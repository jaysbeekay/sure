# Loan checks for the built image (RAILS_ENV=production), in two runs:
#   bin/rails runner verify.rb ui     -- as the demo user, through the real forms
#   bin/rails runner verify.rb model  -- the figures behind the loan the forms made
# Two processes, because a request resets the runner's per-request state.
require "action_dispatch/testing/integration"

$results = []
def check(name, ok, detail = nil)
  $results << ok
  puts "#{ok ? 'PASS' : 'FAIL'}  #{name}#{detail ? "  (#{detail})" : ''}"
end

def finish!
  failed = $results.count(false)
  puts "\n#{$results.size - failed}/#{$results.size} checks passed"
  exit(failed.zero? ? 0 : 1)
end

LOAN_NAME = "Verify Mortgage".freeze

case ARGV.first
when "ui"
  s = ActionDispatch::Integration::Session.new(Rails.application)
  s.host! "localhost"
  # The page's global token, which Rails accepts for any form; a hidden
  # authenticity_token may belong to another form on the page.
  token_from = ->(body) { body[/name="csrf-token" content="([^"]+)"/, 1] || body[/name="authenticity_token" value="([^"]+)"/, 1] }

  s.get "/sessions/new"
  s.post "/sessions", params: { authenticity_token: token_from.(s.response.body), email: "user@example.com", password: "Password1!" }
  check "sign in", s.response.redirect?, "status #{s.response.status}"

  # The fork's demo loans carry no terms, so make one the way a user would:
  # the new-loan form (#393), then the edit form for its rate changes,
  # down payment and insurance.
  s.get "/loans/new"
  check "new-loan form renders (#393)", s.response.status == 200, "status #{s.response.status}"
  start = Date.current << 30
  s.post "/loans", params: {
    authenticity_token: token_from.(s.response.body),
    account: {
      name: LOAN_NAME, balance: 385_000, currency: "USD", accountable_type: "Loan",
      accountable_attributes: {
        subtype: "mortgage", rate_type: "variable", interest_rate: 6.1, term_months: 360,
        initial_balance: 400_000, start_date: start.iso8601, day_count_convention: "actual_365"
      }
    }
  }
  check "new-loan form creates the loan", s.response.redirect?, "status #{s.response.status}"
  account_path = URI(s.response.location).path
  loan_id = account_path.split("/").last

  s.get "/loans/#{loan_id}/edit"
  form = s.response.body
  check "loan edit form renders", s.response.status == 200, "status #{s.response.status}"
  %w[actual_365 actual_actual thirty_360 actual_360].each do |basis|
    check "edit form offers #{basis} (#397/#398)", form.include?("value=\"#{basis}\"")
  end
  check "edit form has down payment and insurance fields (#402)", form.include?("down_payment") && form.include?("insurance_rate")

  s.patch "/loans/#{loan_id}", params: {
    authenticity_token: token_from.(form),
    account: {
      accountable_attributes: {
        id: Account.find(loan_id).accountable_id,
        down_payment: 100_000, insurance_rate: 0.36, insurance_rate_type: "level_term",
        rate_changes: [
          { effective_date: (Date.current << 6).iso8601, rate: "6.43" },
          { effective_date: (Date.current >> 2).iso8601, rate: "6.18" }
        ]
      }
    }
  }
  check "edit form saves rate changes, down payment and insurance", s.response.redirect?, "status #{s.response.status}"

  s.get account_path, params: { tab: "schedule" }
  check "loan page (Schedule tab) renders", s.response.status == 200, "status #{s.response.status}"
  check "exactly one loan chart on the page (#403)", s.response.body.scan('data-controller="loan-payoff-chart"').size == 1
  check "rate-change table renders (#394)", s.response.body.include?("data-rate-change-table")

  s.get account_path, params: { tab: "extra_repayments", extra_payment: { amount: "250" } }
  check "Extra repayments tab renders with an amount", s.response.status == 200, "status #{s.response.status}"
  check "one chart, carrying the extra series (#403)",
    s.response.body.scan('data-controller="loan-payoff-chart"').size == 1 && s.response.body.include?("extra_payoff_date")

  s.get account_path, params: { tab: "overview" }
  check "Overview renders insurance, leverage and repayment progress (#402)",
    s.response.status == 200 && s.response.body.include?("donut-chart") && s.response.body.include?("Leverage")

  s.get "/rules/new", params: { resource_type: "transaction" }
  check "rule form offers the loan rate-change action (#400)", s.response.status == 200 && s.response.body.include?("record_loan_rate_change")
  finish!

when "model"
  account = Account.find_by!(name: LOAN_NAME)
  loan = account.loan
  as_of = Date.current
  schedule = loan.amortization_schedule
  amortizable = loan.respond_to?(:amortizable?) ? loan.amortizable? : schedule.amortizable?
  amount_of = ->(row) { v = row.respond_to?(:payment) ? row.payment : row[:payment_amount]; v.respond_to?(:amount) ? v.amount : BigDecimal(v.to_s) }
  date_of = ->(row) { row.respond_to?(:date) ? row.date : row[:payment_date] }

  check "the form-made loan is amortizable", amortizable
  check "its rate changes were recorded by the edit form", loan.variable_rate_schedule.size == 2, loan.variable_rate_schedule.keys.join(",")
  check "new loans default to thirty_360 (#397)", Loan.new.day_count_convention == "thirty_360"
  expected = amount_of.(schedule.payments.find { |row| date_of.(row) > as_of })
  check "current minimum payment is the schedule row in force (#394)", loan.current_minimum_payment(as_of: as_of).amount == expected, expected.to_s
  check "rate-change table lists the forthcoming change (#394)", UI::Loan::RateChangeTable.new(loan: loan, as_of: as_of).rows.size == 1
  check "default projection pays the schedule's repayment in force (#401)", amount_of.(Loan::PayoffProjection.new(loan, as_of: as_of).payments.first) == expected
  check "principal is the recorded initial balance (#402)", loan.original_balance.amount == BigDecimal("400000")
  check "insurance and leverage compute (#402)", loan.total_insurance.amount.positive? && loan.leverage_band.present?
  %w[thirty_360 actual_360 actual_365].each do |basis|
    loan.update!(day_count_convention: basis)
    check "loan saves #{basis} through the DB constraint (#397/#398)", loan.reload.day_count_convention == basis
  end
  check "rate-change rule action registered (#400)",
    Rule.new(resource_type: "transaction", family: account.family).registry.action_executors.map(&:key).include?("record_loan_rate_change")
  check "parser reads 'NEW RATE 6.24% P.A.' and refuses 'Rate decreased 0.25%' (#400)",
    Loan::RateChangeText.parse("NEW RATE 6.24% P.A.") == BigDecimal("6.24") && Loan::RateChangeText.parse("Rate decreased 0.25%").nil?
  check "upstream 20260908145118 recorded as migrated (#396)",
    ActiveRecord::Base.connection.select_values("SELECT version FROM schema_migrations").include?("20260908145118")
  finish!
else
  abort "usage: bin/rails runner verify.rb ui|model"
end
