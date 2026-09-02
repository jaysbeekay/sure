json.loan do
  json.id loan.id
  json.account_id loan.account.id
  json.name loan.account.name
  json.rate_type loan.rate_type
  json.interest_rate loan.interest_rate.to_f
  json.term_months loan.term_months
  json.original_balance loan.original_balance.to_s
  json.currency loan.account.currency
  json.next_rate_change_date loan.next_rate_change_date
end

json.schedule do
  json.monthly_payment schedule.monthly_payment.to_s
  json.total_interest schedule.total_interest.to_s
  json.total_cost schedule.total_cost.to_s
  json.payoff_date schedule.payoff_date
  json.payment_count schedule.payment_count
  json.has_rate_changes schedule.has_rate_changes?
end

# Actual-balance-based projection: how the payoff shifts if the current
# balance (reflecting any extra/lump-sum payments) is carried forward at the
# same monthly payment, versus the original schedule above. Only present
# when applicable (fixed-rate, amortizable, current balance still positive
# and coverable by the existing payment amount) -- see Loan::PayoffProjection.
if projection.applicable?
  json.payoff_projection do
    json.current_balance projection.current_balance.to_s
    json.projected_payoff_date projection.payoff_date
    json.projected_total_interest projection.total_interest.to_s
    json.months_saved projection.months_saved
    json.interest_saved projection.interest_saved.to_s
  end
else
  json.payoff_projection nil
end

json.pagination do
  json.limit limit
  json.offset offset
  json.total_count total_count
end

json.payments do
  json.array! payments do |payment|
    json.payment_number payment.payment_number
    json.payment_date payment.payment_date
    json.payment_amount payment.payment_amount.to_s
    json.principal_payment payment.principal_payment.to_s
    json.interest_payment payment.interest_payment.to_s
    json.beginning_balance payment.beginning_balance.to_s
    json.ending_balance payment.ending_balance.to_s
    json.interest_rate payment.interest_rate.to_f
  end
end
