class CreateForecastProjectionTraces < ActiveRecord::Migration[7.2]
  def change
    create_table :forecast_projection_traces, id: :uuid do |t|
      t.references :forecast_projection_cache, null: false, foreign_key: { on_delete: :cascade }, type: :uuid
      t.string :period_key, null: false
      t.string :granularity, null: false
      t.uuid :assumption_id
      t.string :source_type
      t.uuid :source_id
      t.string :metric_key, null: false
      t.string :direction
      t.decimal :amount, precision: 19, scale: 4
      t.string :currency
      t.string :category
      t.integer :display_order, null: false, default: 0
      t.string :trace_kind, null: false
      t.string :explanation_key
      t.jsonb :source_record_refs, null: false, default: {}
      t.timestamps
    end

    add_index :forecast_projection_traces,
      %i[forecast_projection_cache_id period_key granularity],
      name: "idx_forecast_projection_traces_cache_period"
    add_index :forecast_projection_traces,
      %i[assumption_id period_key],
      where: "assumption_id IS NOT NULL",
      name: "idx_forecast_projection_traces_assumption_period"
  end
end
