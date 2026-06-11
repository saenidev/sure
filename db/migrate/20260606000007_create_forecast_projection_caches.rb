class CreateForecastProjectionCaches < ActiveRecord::Migration[7.2]
  def change
    create_table :forecast_projection_caches, id: :uuid do |t|
      t.references :forecast_plan, null: false, foreign_key: { on_delete: :cascade }, type: :uuid
      t.references :forecast_source_snapshot, null: true, foreign_key: { on_delete: :nullify }, type: :uuid
      t.integer :plan_version, null: false
      t.string :scenario_stack_key, null: false
      t.string :scenario_stack_hash, null: false
      t.string :source_snapshot_hash, null: false
      t.string :engine_version, null: false
      t.string :projection_result_hash
      t.string :status, null: false, default: "recomputing"
      t.datetime :started_at
      t.datetime :finished_at
      t.string :error_code
      t.jsonb :issue_summary, null: false, default: {}
      t.timestamps
    end

    add_index :forecast_projection_caches,
      %i[forecast_plan_id scenario_stack_hash source_snapshot_hash plan_version engine_version],
      unique: true,
      where: "status <> 'superseded'",
      name: "idx_forecast_projection_caches_current_key"

    add_index :forecast_projection_caches, %i[forecast_plan_id status], name: "idx_forecast_projection_caches_plan_status"
  end
end
