class CreateForecastSourceSnapshots < ActiveRecord::Migration[7.2]
  def change
    create_table :forecast_source_snapshots, id: :uuid do |t|
      t.references :forecast_plan, null: false, foreign_key: { on_delete: :cascade }, type: :uuid
      t.references :family, null: false, foreign_key: { on_delete: :cascade }, type: :uuid
      t.string :source_snapshot_hash, null: false
      t.date :as_of, null: false
      t.string :freshness_state, null: false, default: "fresh"
      t.jsonb :included_account_ids, null: false, default: []
      t.jsonb :source_versions, null: false, default: {}
      t.jsonb :issue_candidates, null: false, default: []
      t.jsonb :snapshot_payload, null: false, default: {}
      t.string :created_by_event
      t.string :schema_version, null: false, default: "forecast-source-snapshot-v1"
      t.datetime :expires_at
      t.timestamps
    end

    add_index :forecast_source_snapshots, %i[forecast_plan_id source_snapshot_hash], name: "idx_forecast_source_snapshots_plan_hash"
    add_index :forecast_source_snapshots, %i[family_id as_of], name: "idx_forecast_source_snapshots_family_as_of"
    add_index :forecast_source_snapshots, %i[forecast_plan_id freshness_state], name: "idx_forecast_source_snapshots_plan_freshness"
    add_index :forecast_source_snapshots, :expires_at, name: "idx_forecast_source_snapshots_expires_at"
  end
end
