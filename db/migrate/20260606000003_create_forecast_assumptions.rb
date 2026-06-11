class CreateForecastAssumptions < ActiveRecord::Migration[7.2]
  def change
    create_table :forecast_assumptions, id: :uuid do |t|
      t.references :forecast_plan, null: false, foreign_key: { on_delete: :cascade }, type: :uuid
      t.references :family, null: false, foreign_key: { on_delete: :cascade }, type: :uuid
      t.string :kind, null: false
      t.string :name, null: false
      t.string :status, null: false, default: "active"
      t.date :starts_on
      t.date :ends_on
      t.references :starts_at_milestone, foreign_key: { to_table: :forecast_milestones, on_delete: :nullify }, type: :uuid
      t.references :ends_at_milestone, foreign_key: { to_table: :forecast_milestones, on_delete: :nullify }, type: :uuid
      t.string :currency
      t.decimal :amount, precision: 19, scale: 4
      t.jsonb :params, null: false, default: {}
      t.string :source_record_type
      t.uuid :source_record_id
      t.string :origin, null: false, default: "user_created"
      t.string :confidence
      t.string :review_state, null: false, default: "confirmed"
      t.jsonb :source_refs, null: false, default: {}
      t.datetime :derived_at
      t.string :derivation_version
      t.string :schema_version, null: false, default: "forecast-assumption-v1"
      t.integer :lock_version, null: false, default: 0
      t.timestamps
    end

    add_index :forecast_assumptions, %i[forecast_plan_id status]
    add_index :forecast_assumptions, %i[forecast_plan_id kind]
    add_index :forecast_assumptions, %i[forecast_plan_id starts_on]
    add_index :forecast_assumptions, %i[family_id source_record_type source_record_id], name: "idx_forecast_assumptions_source_record"
    add_index :forecast_assumptions, %i[forecast_plan_id origin review_state], name: "idx_forecast_assumptions_origin_review"
  end
end
