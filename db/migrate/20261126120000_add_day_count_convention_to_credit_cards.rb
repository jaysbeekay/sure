# How a card's daily periodic rate is taken from its APR: the APR over 365
# days, or over 360. Existing cards take actual/365, the common card basis.
#
# A plain string with a check constraint, as `loans.day_count_convention` is:
# adding a basis later is a constraint swap, not a type change.
class AddDayCountConventionToCreditCards < ActiveRecord::Migration[8.1]
  CONVENTIONS = %w[actual_365 actual_360].freeze
  CONSTRAINT = "chk_credit_cards_day_count_convention"

  def change
    add_column :credit_cards, :day_count_convention, :string,
      null: false, default: "actual_365"

    add_check_constraint :credit_cards,
      "day_count_convention IN (#{CONVENTIONS.map { |v| "'#{v}'" }.join(', ')})",
      name: CONSTRAINT
  end
end
