# Runs inside the built image (RAILS_ENV=production). Phase A: model-level checks.
# Phase B: sign in as the demo user and request the loan pages through the full
# Rack stack. Model work all happens in phase A, because a request resets the
# runner's per-request state.
require "action_dispatch/testing/integration"
results = []
check = ->(name, ok, detail = nil) { results << ok; puts "#{ok ? 'PASS' : 'FAIL'}  #{name}#{detail ? "  (#{detail})" : ''}" }

user = User.find_by!(email: "user@example.com")
family = user.family
Current.session = user.sessions.create!

# The fork's demo loans carry no terms, so add a variable mortgage the way the tests do.
loan_account = family.accounts.create!(
  name: "Verify Mortgage", balance: 385_000, currency: family.currency,
  accountable: Loan.new(rate_type: "variable", interest_rate: 6.1, term_months: 360,
                        initial_balance: 400_000, start_date: Date.current - 30.months,
                        day_count_convention: "actual_365")
)
loan = loan_account.loan
loan.add_variable_rate_change(Date.current - 6.months, 6.43)
loan.add_variable_rate_change(Date.current + 2.months, 6.18)
loan.reload
as_of = Date.current

schedule = loan.amortization_schedule
amortizable = loan.respond_to?(:amortizable?) ? loan.amortizable? : schedule.amortizable?
check.("variable loan with terms is amortizable", amortizable)
# Read a row's amount on either engine: the fork's hash rows or upstream's Payment rows.
amount_of = ->(row) { v = row.respond_to?(:payment) ? row.payment : row[:payment_amount]; v.respond_to?(:amount) ? v.amount : BigDecimal(v.to_s) }
date_of = ->(row) { row.respond_to?(:date) ? row.date : row[:payment_date] }
check.("new loans default to thirty_360 (#397)", Loan.new.day_count_convention == "thirty_360")
in_force = schedule.payments.find { |row| date_of.(row) > as_of }
expected = amount_of.(in_force)
check.("current minimum payment is the schedule row in force (#394)", loan.current_minimum_payment(as_of: as_of).amount == expected, expected.to_s)
check.("rate-change table lists the forthcoming change (#394)", UI::Loan::RateChangeTable.new(loan: loan, as_of: as_of).rows.size == 1)
proj = Loan::PayoffProjection.new(loan, as_of: as_of)
check.("default projection pays the schedule's repayment in force (#401)", amount_of.(proj.payments.first) == expected)
check.("Loan::PayoffChart is present (#403)", defined?(Loan::PayoffChart).present?)
check.("principal is the recorded initial balance (#402)", loan.original_balance.amount == BigDecimal("400000"))
loan.update!(down_payment: 100_000, insurance_rate: 0.36, insurance_rate_type: "level_term")
check.("insurance and leverage compute (#402)", loan.reload.total_insurance.amount.positive? && loan.leverage_band.present?)
%w[thirty_360 actual_360 actual_365].each do |basis|
  loan.update!(day_count_convention: basis)
  check.("loan saves #{basis} through the DB constraint (#397/#398)", loan.reload.day_count_convention == basis)
end
check.("rate-change rule action registered (#400)",
  Rule.new(resource_type: "transaction", family: family).registry.action_executors.map(&:key).include?("record_loan_rate_change"))
check.("parser reads 'NEW RATE 6.24% P.A.' and refuses 'Rate decreased 0.25%' (#400)",
  Loan::RateChangeText.parse("NEW RATE 6.24% P.A.") == BigDecimal("6.24") && Loan::RateChangeText.parse("Rate decreased 0.25%").nil?)
check.("upstream 20260908145118 recorded as migrated (#396)",
  ActiveRecord::Base.connection.select_values("SELECT version FROM schema_migrations").include?("20260908145118"))
loan_id = loan_account.id
Current.reset

# Phase B: the pages.
s = ActionDispatch::Integration::Session.new(Rails.application)
s.host! "localhost"
s.get "/sessions/new"
token = s.response.body[/name="authenticity_token" value="([^"]+)"/, 1]
s.post "/sessions", params: { authenticity_token: token, email: "user@example.com", password: "Password1!" }
check.("sign in", s.response.redirect?, "status #{s.response.status}")

s.get "/accounts/#{loan_id}", params: { tab: "schedule" }
check.("loan page (Schedule tab) renders", s.response.status == 200, "status #{s.response.status}")
check.("exactly one loan chart on the page (#403)", s.response.body.scan('data-controller="loan-payoff-chart"').size == 1)
check.("rate-change table renders (#394)", s.response.body.include?("data-rate-change-table"))

s.get "/accounts/#{loan_id}", params: { tab: "extra_repayments", extra_payment: { amount: "250" } }
check.("Extra repayments tab renders with an amount", s.response.status == 200, "status #{s.response.status}")
check.("one chart, carrying the extra series (#403)",
  s.response.body.scan('data-controller="loan-payoff-chart"').size == 1 && s.response.body.include?("extra_payoff_date"))

s.get "/accounts/#{loan_id}", params: { tab: "overview" }
check.("Overview renders insurance, leverage and repayment progress (#402)",
  s.response.status == 200 && s.response.body.include?("donut-chart") && s.response.body.include?("Leverage"))

s.get "/loans/#{loan_id}/edit"
form = s.response.body
check.("loan edit form renders", s.response.status == 200, "status #{s.response.status}")
%w[actual_365 actual_actual thirty_360 actual_360].each do |basis|
  check.("edit form offers #{basis}", form.include?("value=\"#{basis}\""))
end
check.("edit form has down payment and insurance fields (#402)", form.include?("down_payment") && form.include?("insurance_rate"))

s.get "/loans/new"
check.("new-loan form renders (#393)", s.response.status == 200, "status #{s.response.status}")

s.get "/rules/new", params: { resource_type: "transaction" }
check.("rule form offers the loan rate-change action (#400)", s.response.status == 200 && s.response.body.include?("record_loan_rate_change"))

failed = results.count(false)
puts "\n#{results.size - failed}/#{results.size} checks passed"
exit(failed.zero? ? 0 : 1)
