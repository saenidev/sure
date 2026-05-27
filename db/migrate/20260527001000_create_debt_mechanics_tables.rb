class CreateDebtMechanicsTables < ActiveRecord::Migration[7.2]
  def change
    create_table :debt_profiles, id: :uuid do |t|
      t.references :account, null: false, foreign_key: { on_delete: :cascade }, type: :uuid, index: { unique: true }
      t.string :status, null: false, default: "active"
      t.boolean :auto_accrual_enabled, null: false, default: false
      t.boolean :auto_payment_allocation_enabled, null: false, default: false
      t.string :rate_type
      t.string :accrual_cadence
      t.string :compounding_cadence
      t.decimal :minimum_payment_amount, precision: 19, scale: 4
      t.decimal :minimum_payment_percent, precision: 10, scale: 4
      t.integer :payment_due_day
      t.integer :statement_closing_day
      t.integer :grace_period_days
      t.date :effective_start_on
      t.date :effective_end_on
      t.date :last_accrued_on
      t.date :next_due_on
      t.string :source
      t.jsonb :extra, null: false, default: {}

      t.timestamps
    end

    add_index :debt_profiles, :status
    add_index :debt_profiles, :next_due_on
    add_index :debt_profiles, :extra, using: :gin

    create_table :debt_rate_periods, id: :uuid do |t|
      t.references :debt_profile, null: false, foreign_key: { on_delete: :cascade }, type: :uuid
      t.string :rate_type, null: false
      t.decimal :annual_rate, precision: 10, scale: 4, null: false
      t.date :starts_on, null: false
      t.date :ends_on
      t.integer :priority, null: false, default: 0
      t.string :source
      t.string :external_id
      t.jsonb :extra, null: false, default: {}

      t.timestamps
    end

    add_index :debt_rate_periods, [ :debt_profile_id, :starts_on ]
    add_index :debt_rate_periods, [ :debt_profile_id, :source, :external_id ], unique: true, where: "source IS NOT NULL AND external_id IS NOT NULL"
    add_index :debt_rate_periods, :extra, using: :gin

    create_table :debt_events, id: :uuid do |t|
      t.references :account, null: false, foreign_key: { on_delete: :cascade }, type: :uuid
      t.references :debt_profile, null: true, foreign_key: { on_delete: :nullify }, type: :uuid
      t.references :entry, null: true, foreign_key: { on_delete: :nullify }, type: :uuid
      t.string :event_type, null: false
      t.string :status, null: false
      t.date :event_date, null: false
      t.date :period_start_on
      t.date :period_end_on
      t.decimal :amount, precision: 19, scale: 4, null: false
      t.string :currency, null: false
      t.string :source
      t.string :external_id
      t.string :idempotency_key
      t.jsonb :extra, null: false, default: {}

      t.timestamps
    end

    add_index :debt_events, [ :account_id, :event_date ]
    add_index :debt_events, [ :account_id, :event_type, :status ]
    add_index :debt_events, [ :account_id, :idempotency_key ], unique: true, where: "idempotency_key IS NOT NULL"
    add_index :debt_events, [ :account_id, :source, :external_id ], unique: true, where: "source IS NOT NULL AND external_id IS NOT NULL"
    add_index :debt_events, :extra, using: :gin

    create_table :debt_obligations, id: :uuid do |t|
      t.references :account, null: false, foreign_key: { on_delete: :cascade }, type: :uuid
      t.references :debt_profile, null: true, foreign_key: { on_delete: :nullify }, type: :uuid
      t.date :statement_on
      t.date :period_start_on
      t.date :period_end_on
      t.date :due_on, null: false
      t.string :status, null: false
      t.decimal :statement_balance_amount, precision: 19, scale: 4
      t.decimal :minimum_payment_amount, precision: 19, scale: 4
      t.decimal :principal_due_amount, precision: 19, scale: 4
      t.decimal :interest_due_amount, precision: 19, scale: 4
      t.decimal :fee_due_amount, precision: 19, scale: 4
      t.decimal :paid_amount, precision: 19, scale: 4, null: false, default: 0
      t.string :currency, null: false
      t.string :source
      t.string :external_id
      t.jsonb :extra, null: false, default: {}

      t.timestamps
    end

    add_index :debt_obligations, [ :account_id, :due_on ]
    add_index :debt_obligations, [ :account_id, :status ]
    add_index :debt_obligations, [ :account_id, :due_on, :source, :external_id ], unique: true, where: "source IS NOT NULL AND external_id IS NOT NULL"
    add_index :debt_obligations, :extra, using: :gin

    create_table :debt_payment_allocations, id: :uuid do |t|
      t.references :account, null: false, foreign_key: { on_delete: :cascade }, type: :uuid
      t.references :entry, null: false, foreign_key: { on_delete: :cascade }, type: :uuid, index: { unique: true }
      t.references :debt_profile, null: true, foreign_key: { on_delete: :nullify }, type: :uuid
      t.references :debt_obligation, null: true, foreign_key: { on_delete: :nullify }, type: :uuid
      t.string :allocation_method, null: false
      t.string :status, null: false
      t.decimal :principal_amount, precision: 19, scale: 4, null: false, default: 0
      t.decimal :interest_amount, precision: 19, scale: 4, null: false, default: 0
      t.decimal :fee_amount, precision: 19, scale: 4, null: false, default: 0
      t.decimal :unapplied_amount, precision: 19, scale: 4, null: false, default: 0
      t.string :currency, null: false
      t.string :source
      t.string :external_id
      t.jsonb :extra, null: false, default: {}

      t.timestamps
    end

    add_index :debt_payment_allocations, [ :account_id, :status ]
    add_index :debt_payment_allocations, [ :account_id, :source, :external_id ], unique: true, where: "source IS NOT NULL AND external_id IS NOT NULL"
    add_index :debt_payment_allocations, :extra, using: :gin

    create_table :debt_reconciliation_matches, id: :uuid do |t|
      t.references :account, null: false, foreign_key: { on_delete: :cascade }, type: :uuid
      t.references :debt_event, null: false, foreign_key: { on_delete: :cascade }, type: :uuid
      t.references :entry, null: false, foreign_key: { on_delete: :cascade }, type: :uuid
      t.string :match_type, null: false
      t.string :confidence, null: false
      t.string :status, null: false
      t.date :matched_on
      t.jsonb :extra, null: false, default: {}

      t.timestamps
    end

    add_index :debt_reconciliation_matches, [ :account_id, :status ]
    add_index :debt_reconciliation_matches, [ :debt_event_id, :entry_id ], unique: true
    add_index :debt_reconciliation_matches, :debt_event_id, unique: true, where: "status = 'accepted'", name: "idx_debt_matches_one_accepted_per_event"
    add_index :debt_reconciliation_matches, :entry_id, unique: true, where: "status = 'accepted'", name: "idx_debt_matches_one_accepted_per_entry"
    add_index :debt_reconciliation_matches, :extra, using: :gin

    create_table :debt_posting_runs, id: :uuid do |t|
      t.references :account, null: false, foreign_key: { on_delete: :cascade }, type: :uuid
      t.references :debt_profile, null: true, foreign_key: { on_delete: :nullify }, type: :uuid
      t.string :run_type, null: false
      t.date :period_start_on
      t.date :period_end_on
      t.string :status, null: false
      t.datetime :started_at
      t.datetime :finished_at
      t.string :error_class
      t.text :error_message
      t.jsonb :extra, null: false, default: {}

      t.timestamps
    end

    add_index :debt_posting_runs, [ :account_id, :run_type, :period_start_on, :period_end_on ], name: "index_debt_posting_runs_on_account_run_type_period"
    add_index :debt_posting_runs, :extra, using: :gin
  end
end
