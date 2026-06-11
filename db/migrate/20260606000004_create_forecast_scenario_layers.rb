class CreateForecastScenarioLayers < ActiveRecord::Migration[7.2]
  def change
    create_table :forecast_scenario_layers, id: :uuid do |t|
      t.references :forecast_plan, null: false, foreign_key: { on_delete: :cascade }, type: :uuid
      t.string :name, null: false
      t.text :description
      t.string :status, null: false, default: "active"
      t.integer :position, null: false, default: 0
      t.string :color_token
      t.references :base_layer, foreign_key: { to_table: :forecast_scenario_layers, on_delete: :nullify }, type: :uuid
      t.jsonb :settings, null: false, default: {}
      t.timestamps
    end

    add_index :forecast_scenario_layers, %i[forecast_plan_id status position], name: "idx_forecast_scenario_layers_plan_status_pos"
    add_index :forecast_scenario_layers, %i[forecast_plan_id base_layer_id], name: "idx_forecast_scenario_layers_plan_base"
  end
end
