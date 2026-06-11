class CreateForecastProjectionPeriods < ActiveRecord::Migration[7.2]
  def change
    create_table :forecast_projection_periods, id: :uuid do |t|
      t.references :forecast_projection_cache, null: false, foreign_key: { on_delete: :cascade }, type: :uuid
      t.references :forecast_plan, null: false, foreign_key: { on_delete: :cascade }, type: :uuid
      t.string :scenario_stack_key, null: false
      t.string :period_key, null: false
      t.date :period_start_on, null: false
      t.date :period_end_on, null: false
      t.string :granularity, null: false
      t.jsonb :metrics, null: false, default: {}
      # Per-period explanation traces, embedded as a compact jsonb array instead
      # of relational rows (9k trace inserts -> 361 period inserts on a 30-year
      # save). Ordered: array position IS display order (the engine's ledger
      # order). Zero-amount traces are filtered before storage. Entry key map is
      # documented on Forecasts::ProjectionPeriod::TRACE_KEYS.
      t.jsonb :traces, null: false, default: []
      t.jsonb :issue_codes, null: false, default: []
      t.jsonb :active_assumption_ids, null: false, default: []
      t.integer :plan_version, null: false
      t.string :engine_version, null: false
      t.timestamps
    end

    add_index :forecast_projection_periods,
      %i[forecast_plan_id scenario_stack_key period_key granularity],
      name: "idx_forecast_projection_periods_plan_stack_period"
    add_index :forecast_projection_periods,
      %i[forecast_projection_cache_id period_key granularity],
      name: "idx_forecast_projection_periods_cache_period"
    add_index :forecast_projection_periods,
      %i[forecast_plan_id plan_version],
      name: "idx_forecast_projection_periods_plan_version"
  end
end
