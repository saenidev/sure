class CreateForecastPlanningTables < ActiveRecord::Migration[7.2]
  def change
    create_table :forecast_scenarios, id: :uuid do |t|
      t.references :family, null: false, foreign_key: { on_delete: :cascade }, type: :uuid
      t.references :created_by_user, foreign_key: { to_table: :users, on_delete: :nullify }, type: :uuid
      t.references :parent_scenario, foreign_key: { to_table: :forecast_scenarios, on_delete: :nullify }, type: :uuid
      t.string :name, null: false
      t.text :description
      t.string :status, null: false, default: "active"
      t.string :approval_status, null: false, default: "manual"
      t.integer :position, null: false, default: 0
      t.date :starts_on
      t.date :ends_on
      t.string :color
      t.jsonb :assumptions, null: false, default: {}
      t.jsonb :source_metadata, null: false, default: {}
      t.timestamps
    end

    add_index :forecast_scenarios, %i[family_id status position]

    create_table :forecast_events, id: :uuid do |t|
      t.references :family, null: false, foreign_key: { on_delete: :cascade }, type: :uuid
      t.references :forecast_scenario, foreign_key: true, type: :uuid
      t.references :account, foreign_key: { on_delete: :nullify }, type: :uuid
      t.references :destination_account, foreign_key: { to_table: :accounts, on_delete: :nullify }, type: :uuid
      t.references :category, foreign_key: { on_delete: :nullify }, type: :uuid
      t.string :name, null: false
      t.text :description
      t.string :effect_type, null: false
      t.string :behavior, null: false, default: "additive"
      t.decimal :amount, precision: 19, scale: 4
      t.string :currency
      t.date :starts_on, null: false
      t.date :ends_on
      t.jsonb :recurrence_rule, null: false, default: {}
      t.string :status, null: false, default: "planned"
      t.decimal :probability_weight, precision: 8, scale: 4, null: false, default: 1
      t.integer :apply_order, null: false, default: 0
      t.jsonb :source_metadata, null: false, default: {}
      t.timestamps
    end

    add_index :forecast_events, %i[family_id starts_on]
    add_index :forecast_events, %i[forecast_scenario_id starts_on]

    create_table :forecast_event_links, id: :uuid do |t|
      t.references :family, null: false, foreign_key: true, type: :uuid
      t.references :forecast_event, foreign_key: { on_delete: :nullify }, type: :uuid
      t.references :entry, foreign_key: { on_delete: :nullify }, type: :uuid
      t.date :occurrence_on
      t.string :link_type, null: false
      t.string :status, null: false, default: "candidate"
      t.decimal :confidence, precision: 8, scale: 4
      t.jsonb :event_snapshot, null: false, default: {}
      t.jsonb :entry_snapshot, null: false, default: {}
      t.jsonb :match_metadata, null: false, default: {}
      t.timestamps
    end

    add_index :forecast_event_links, %i[forecast_event_id occurrence_on], name: "idx_event_links_event_occurrence"
    add_index :forecast_event_links, %i[forecast_event_id occurrence_on], unique: true, where: "status = 'accepted' AND forecast_event_id IS NOT NULL AND occurrence_on IS NOT NULL", name: "idx_event_links_accepted_occurrence"
    add_index :forecast_event_links, %i[forecast_event_id entry_id], unique: true, where: "entry_id IS NOT NULL"
    add_index :forecast_event_links, :entry_id, unique: true, where: "status = 'accepted' AND entry_id IS NOT NULL", name: "idx_event_links_unique_accepted_entry"
    add_index :forecast_event_links, %i[family_id status]

    create_table :forecast_budget_overrides, id: :uuid do |t|
      t.references :family, null: false, foreign_key: true, type: :uuid
      t.references :forecast_scenario, foreign_key: { on_delete: :cascade }, type: :uuid
      t.references :category, foreign_key: { on_delete: :cascade }, type: :uuid
      t.date :period_start_on, null: false
      t.string :override_type, null: false
      t.decimal :amount, precision: 19, scale: 4, null: false
      t.string :currency, null: false
      t.string :status, null: false, default: "active"
      t.text :note
      t.jsonb :source_metadata, null: false, default: {}
      t.timestamps
    end

    add_index :forecast_budget_overrides, %i[family_id period_start_on status], name: "idx_budget_overrides_period_status"
    add_index :forecast_budget_overrides,
      "family_id, COALESCE(forecast_scenario_id, '00000000-0000-0000-0000-000000000000'::uuid), period_start_on, override_type, COALESCE(category_id, '00000000-0000-0000-0000-000000000000'::uuid)",
      unique: true,
      where: "status = 'active'",
      name: "idx_budget_overrides_unique_active"

    create_table :forecast_goals, id: :uuid do |t|
      t.references :family, null: false, foreign_key: true, type: :uuid
      t.references :forecast_scenario, foreign_key: true, type: :uuid
      t.string :name, null: false
      t.string :goal_type, null: false
      t.decimal :target_amount, precision: 19, scale: 4
      t.string :currency
      t.integer :target_duration_days
      t.date :target_date
      t.date :starts_on
      t.date :ends_on
      t.boolean :required, null: false, default: false
      t.string :blocking_behavior, null: false, default: "warn"
      t.string :status, null: false, default: "active"
      t.jsonb :condition_metadata, null: false, default: {}
      t.timestamps
    end

    add_index :forecast_goals, %i[family_id status]
    add_index :forecast_goals, %i[forecast_scenario_id status]

    create_table :forecast_account_liquidity_settings, id: :uuid do |t|
      t.references :family, null: false, foreign_key: true, type: :uuid
      t.references :forecast_scenario, foreign_key: true, type: :uuid
      t.references :account, null: false, foreign_key: { on_delete: :cascade }, type: :uuid
      t.string :liquidity_class, null: false
      t.date :starts_on
      t.date :ends_on
      t.jsonb :constraints, null: false, default: {}
      t.timestamps
    end

    add_index :forecast_account_liquidity_settings,
      %i[family_id account_id starts_on ends_on],
      where: "forecast_scenario_id IS NULL",
      name: "idx_forecast_liquidity_baseline_window"
    add_index :forecast_account_liquidity_settings,
      %i[family_id forecast_scenario_id account_id starts_on ends_on],
      where: "forecast_scenario_id IS NOT NULL",
      name: "idx_forecast_liquidity_scenario_window"
  end
end
