class CreateForecastOutputTables < ActiveRecord::Migration[7.2]
  def change
    create_table :forecast_run_groups, id: :uuid do |t|
      t.references :family, null: false, foreign_key: true, type: :uuid
      t.references :user, foreign_key: { on_delete: :nullify }, type: :uuid
      t.references :supersedes_forecast_run_group, foreign_key: { to_table: :forecast_run_groups, on_delete: :nullify }, type: :uuid
      t.string :name, null: false
      t.string :run_type, null: false
      t.string :status, null: false, default: "pending"
      t.string :currency, null: false
      t.date :horizon_start_on, null: false
      t.date :horizon_end_on, null: false
      t.date :daily_until_on, null: false
      t.string :engine_version, null: false, default: "forecast-engine-v1"
      t.string :input_schema_version, null: false, default: "forecast-input-v1"
      t.jsonb :user_snapshot, null: false, default: {}
      t.jsonb :currency_snapshot, null: false, default: {}
      t.jsonb :trigger_metadata, null: false, default: {}
      t.jsonb :source_data_versions, null: false, default: {}
      t.jsonb :risk_flags, null: false, default: []
      t.datetime :started_at
      t.datetime :finished_at
      t.text :error_message
      t.timestamps
    end

    add_index :forecast_run_groups, %i[family_id created_at]
    add_index :forecast_run_groups, %i[family_id run_type status]

    create_table :forecast_runs, id: :uuid do |t|
      t.references :forecast_run_group, null: false, foreign_key: { on_delete: :cascade }, type: :uuid
      t.references :family, null: false, foreign_key: { on_delete: :cascade }, type: :uuid
      t.references :user, foreign_key: { on_delete: :nullify }, type: :uuid
      t.string :scenario_stack_key, null: false
      t.jsonb :scenario_stack_snapshot, null: false, default: {}
      t.string :status, null: false, default: "pending"
      t.string :feasibility_status, null: false, default: "unknown"
      t.string :currency, null: false
      t.jsonb :user_snapshot, null: false, default: {}
      t.jsonb :input_snapshot, null: false, default: {}
      t.jsonb :source_contributions, null: false, default: {}
      t.jsonb :risk_flags, null: false, default: []
      t.datetime :started_at
      t.datetime :finished_at
      t.text :error_message
      t.timestamps
    end

    add_index :forecast_runs, %i[forecast_run_group_id scenario_stack_key], unique: true, name: "idx_forecast_runs_group_stack"
    add_index :forecast_runs, %i[family_id created_at]

    create_table :forecast_days, id: :uuid do |t|
      t.references :forecast_run, null: false, foreign_key: { on_delete: :cascade }, type: :uuid
      t.date :date, null: false
      t.string :scenario_stack_key, null: false
      t.string :currency, null: false
      t.decimal :expected_income, precision: 19, scale: 4, null: false, default: 0
      t.decimal :expected_spending, precision: 19, scale: 4, null: false, default: 0
      t.decimal :pending_income, precision: 19, scale: 4, null: false, default: 0
      t.decimal :pending_spending, precision: 19, scale: 4, null: false, default: 0
      t.decimal :cash_balance, precision: 19, scale: 4, null: false, default: 0
      t.decimal :liquid_balance, precision: 19, scale: 4, null: false, default: 0
      t.decimal :portfolio_value, precision: 19, scale: 4, null: false, default: 0
      t.decimal :debt_balance, precision: 19, scale: 4, null: false, default: 0
      t.decimal :net_worth, precision: 19, scale: 4, null: false, default: 0
      t.integer :cash_runway_days
      t.integer :liquid_runway_days
      t.jsonb :source_breakdown, null: false, default: {}
      t.jsonb :risk_flags, null: false, default: []
      t.timestamps
    end

    add_index :forecast_days, %i[forecast_run_id date scenario_stack_key], unique: true, name: "idx_forecast_days_run_date_stack"

    create_table :forecast_months, id: :uuid do |t|
      t.references :forecast_run, null: false, foreign_key: { on_delete: :cascade }, type: :uuid
      t.date :period_start_on, null: false
      t.date :period_end_on, null: false
      t.string :scenario_stack_key, null: false
      t.string :precision, null: false
      t.string :currency, null: false
      t.decimal :expected_income, precision: 19, scale: 4, null: false, default: 0
      t.decimal :expected_spending, precision: 19, scale: 4, null: false, default: 0
      t.decimal :net_cash_flow, precision: 19, scale: 4, null: false, default: 0
      t.decimal :cash_balance, precision: 19, scale: 4, null: false, default: 0
      t.decimal :liquid_balance, precision: 19, scale: 4, null: false, default: 0
      t.decimal :portfolio_value, precision: 19, scale: 4, null: false, default: 0
      t.decimal :debt_balance, precision: 19, scale: 4, null: false, default: 0
      t.decimal :net_worth, precision: 19, scale: 4, null: false, default: 0
      t.integer :cash_runway_days
      t.integer :liquid_runway_days
      t.jsonb :source_breakdown, null: false, default: {}
      t.jsonb :risk_flags, null: false, default: []
      t.timestamps
    end

    add_index :forecast_months, %i[forecast_run_id period_start_on scenario_stack_key], unique: true, name: "idx_forecast_months_run_period_stack"

    create_table :forecast_category_projections, id: :uuid do |t|
      t.references :forecast_month, null: false, foreign_key: { on_delete: :cascade }, type: :uuid
      t.references :category, foreign_key: { on_delete: :nullify }, type: :uuid
      t.references :parent_category, foreign_key: { to_table: :categories, on_delete: :nullify }, type: :uuid
      t.string :projection_key, null: false
      t.string :source, null: false
      t.string :currency, null: false
      t.decimal :budgeted_spending, precision: 19, scale: 4, null: false, default: 0
      t.decimal :actual_spending, precision: 19, scale: 4, null: false, default: 0
      t.decimal :pending_spending, precision: 19, scale: 4, null: false, default: 0
      t.decimal :planned_spending, precision: 19, scale: 4, null: false, default: 0
      t.decimal :projected_spending_low, precision: 19, scale: 4, null: false, default: 0
      t.decimal :projected_spending_expected, precision: 19, scale: 4, null: false, default: 0
      t.decimal :projected_spending_high, precision: 19, scale: 4, null: false, default: 0
      t.decimal :projected_spending, precision: 19, scale: 4, null: false, default: 0
      t.decimal :available_to_spend, precision: 19, scale: 4, null: false, default: 0
      t.boolean :inherits_parent_budget, null: false, default: false
      t.jsonb :source_snapshot, null: false, default: {}
      t.jsonb :source_breakdown, null: false, default: {}
      t.jsonb :risk_flags, null: false, default: []
      t.timestamps
    end

    add_index :forecast_category_projections, %i[forecast_month_id projection_key source], unique: true, name: "idx_forecast_category_projection_key"

    create_table :forecast_debt_projections, id: :uuid do |t|
      t.references :forecast_month, null: false, foreign_key: { on_delete: :cascade }, type: :uuid
      t.references :account, foreign_key: { on_delete: :nullify }, type: :uuid
      t.references :debt_profile, foreign_key: { on_delete: :nullify }, type: :uuid
      t.string :projection_key, null: false
      t.string :currency, null: false
      t.decimal :opening_balance, precision: 19, scale: 4, null: false, default: 0
      t.decimal :projected_interest, precision: 19, scale: 4, null: false, default: 0
      t.decimal :projected_payment, precision: 19, scale: 4, null: false, default: 0
      t.decimal :cash_payment_gap, precision: 19, scale: 4, null: false, default: 0
      t.decimal :projected_drawdown, precision: 19, scale: 4, null: false, default: 0
      t.decimal :ending_balance, precision: 19, scale: 4, null: false, default: 0
      t.string :source, null: false
      t.jsonb :risk_flags, null: false, default: []
      t.jsonb :source_snapshot, null: false, default: {}
      t.jsonb :source_breakdown, null: false, default: {}
      t.timestamps
    end

    add_index :forecast_debt_projections, %i[forecast_month_id projection_key], unique: true

    create_table :forecast_goal_evaluations, id: :uuid do |t|
      t.references :forecast_run, null: false, foreign_key: { on_delete: :cascade }, type: :uuid
      t.references :forecast_goal, foreign_key: { on_delete: :nullify }, type: :uuid
      t.string :goal_key, null: false
      t.string :scenario_stack_key, null: false
      t.string :status, null: false
      t.string :currency
      t.decimal :metric_value, precision: 19, scale: 4
      t.decimal :target_value, precision: 19, scale: 4
      t.date :evaluated_on
      t.jsonb :goal_snapshot, null: false, default: {}
      t.jsonb :details, null: false, default: {}
      t.timestamps
    end

    add_index :forecast_goal_evaluations, %i[forecast_run_id goal_key scenario_stack_key], unique: true, name: "idx_forecast_goal_eval_unique"

    create_table :forecast_reviews, id: :uuid do |t|
      t.references :forecast_run_group, null: false, foreign_key: { on_delete: :cascade }, type: :uuid, index: false
      t.references :family, null: false, foreign_key: { on_delete: :cascade }, type: :uuid
      t.references :user, foreign_key: { on_delete: :nullify }, type: :uuid
      t.string :source, null: false
      t.string :status, null: false, default: "draft"
      t.jsonb :user_snapshot, null: false, default: {}
      t.jsonb :request_packet, null: false, default: {}
      t.jsonb :response_packet, null: false, default: {}
      t.datetime :approved_at
      t.datetime :rejected_at
      t.timestamps
    end

    add_index :forecast_reviews, %i[family_id source status]
    add_index :forecast_reviews, :forecast_run_group_id, unique: true
  end
end
