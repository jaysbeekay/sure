class CreateEvents < ActiveRecord::Migration[8.1]
  def change
    # A dated lens over a family's spending (#130, 11.2): "what did the Bali
    # trip cost?". Which transactions belong is derived from the date range;
    # event_transactions holds only the manual overrides.
    create_table :events, id: :uuid do |t|
      t.references :family, null: false, type: :uuid, foreign_key: true
      t.string :name, null: false
      # Both ends inclusive.
      t.date :start_date, null: false
      t.date :end_date, null: false
      t.string :color, null: false, default: "#6471eb"

      t.timestamps
    end

    add_check_constraint :events, "end_date >= start_date", name: "chk_events_date_order"

    # included: pulls in a transaction dated outside the range.
    # excluded: removes one dated inside it.
    create_table :event_transactions, id: :uuid do |t|
      t.references :event, null: false, type: :uuid, foreign_key: { on_delete: :cascade }
      t.references :transaction, null: false, type: :uuid, foreign_key: { on_delete: :cascade }
      t.string :inclusion, null: false

      t.timestamps
    end

    add_check_constraint :event_transactions, "inclusion IN ('included', 'excluded')", name: "chk_event_transactions_inclusion"
    add_index :event_transactions, [ :event_id, :transaction_id ], unique: true, name: "index_event_transactions_on_event_and_transaction"
  end
end
