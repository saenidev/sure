class AddForecastEventScenarioMemberships < ActiveRecord::Migration[7.2]
  def up
    add_column :forecast_events, :include_baseline, :boolean

    create_table :forecast_event_scenario_memberships, id: :uuid do |t|
      t.references :family, null: false, foreign_key: { on_delete: :cascade }, type: :uuid
      t.references :forecast_event, null: false, foreign_key: { on_delete: :cascade }, type: :uuid
      t.references :forecast_scenario, null: false, foreign_key: { on_delete: :cascade }, type: :uuid
      t.timestamps
    end

    add_index :forecast_event_scenario_memberships,
      %i[forecast_event_id forecast_scenario_id],
      unique: true,
      name: "idx_event_scenario_memberships_unique"
    add_index :forecast_event_scenario_memberships,
      %i[family_id forecast_scenario_id],
      name: "idx_event_scenario_memberships_family_scenario"

    execute <<~SQL.squish
      UPDATE forecast_events
      SET include_baseline = (forecast_scenario_id IS NULL)
    SQL

    execute <<~SQL.squish
      INSERT INTO forecast_event_scenario_memberships (
        id,
        family_id,
        forecast_event_id,
        forecast_scenario_id,
        created_at,
        updated_at
      )
      SELECT
        gen_random_uuid(),
        family_id,
        id,
        forecast_scenario_id,
        CURRENT_TIMESTAMP,
        CURRENT_TIMESTAMP
      FROM forecast_events
      WHERE forecast_scenario_id IS NOT NULL
    SQL

    change_column_null :forecast_events, :include_baseline, false
    change_column_default :forecast_events, :include_baseline, from: nil, to: true
    add_index :forecast_events, %i[family_id include_baseline starts_on], name: "idx_forecast_events_baseline_start"
  end

  def down
    remove_index :forecast_events, name: "idx_forecast_events_baseline_start"
    drop_table :forecast_event_scenario_memberships
    remove_column :forecast_events, :include_baseline
  end
end
