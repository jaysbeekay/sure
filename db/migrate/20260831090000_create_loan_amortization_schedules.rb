class CreateLoanAmortizationSchedules < ActiveRecord::Migration[7.2]
  def change
    create_table :loan_amortization_schedules, id: :uuid do |t|
      t.uuid :loan_id, null: false
      t.integer :payment_number, null: false
      t.date :payment_date, null: false
      t.decimal :beginning_balance, precision: 19, scale: 4, null: false
      t.decimal :payment_amount, precision: 19, scale: 4, null: false
      t.decimal :principal_payment, precision: 19, scale: 4, null: false
      t.decimal :interest_payment, precision: 19, scale: 4, null: false
      t.decimal :ending_balance, precision: 19, scale: 4, null: false
      t.decimal :interest_rate, precision: 10, scale: 3, null: false
      t.timestamps

      t.foreign_key :loans, column: :loan_id
      t.index [ :loan_id, :payment_number ], unique: true
      t.index :payment_date
    end
  end
end
