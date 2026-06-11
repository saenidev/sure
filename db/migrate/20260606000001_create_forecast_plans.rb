class CreateForecastPlans < ActiveRecord::Migration[7.2]
  def change
    create_table :forecast_plans, id: :uuid do |t|
      t.references :family, null: false, foreign_key: { on_delete: :cascade }, type: :uuid
      t.string :name, null: false
      t.string :status, null: false, default: "active"
      t.date :horizon_start_on, null: false
      t.date :horizon_end_on, null: false
      t.string :reporting_currency, null: false
      t.jsonb :settings, null: false, default: {}
      t.jsonb :source_policy, null: false, default: {}
      t.integer :current_plan_version, null: false, default: 1
      t.string :schema_version, null: false, default: "forecast-plan-v1"
      t.integer :lock_version, null: false, default: 0
      t.timestamps
    end

    add_index :forecast_plans, %i[family_id status]
    add_index :forecast_plans, %i[family_id created_at]
    add_index :forecast_plans, %i[family_id current_plan_version]
  end
end
