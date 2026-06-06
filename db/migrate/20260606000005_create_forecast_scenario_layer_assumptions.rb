class CreateForecastScenarioLayerAssumptions < ActiveRecord::Migration[7.2]
  def change
    create_table :forecast_scenario_layer_assumptions, id: :uuid do |t|
      t.references :forecast_scenario_layer, null: false, foreign_key: { on_delete: :cascade }, type: :uuid, index: false
      t.references :forecast_assumption, null: false, foreign_key: { on_delete: :cascade }, type: :uuid
      t.string :operation, null: false
      t.jsonb :override_params, null: false, default: {}
      t.boolean :enabled, null: false, default: true
      t.timestamps
    end

    add_index :forecast_scenario_layer_assumptions,
      %i[forecast_scenario_layer_id forecast_assumption_id operation],
      unique: true,
      name: "idx_forecast_layer_assumption_operation"
  end
end
