class CreateForecastMilestones < ActiveRecord::Migration[7.2]
  def change
    create_table :forecast_milestones, id: :uuid do |t|
      t.references :forecast_plan, null: false, foreign_key: { on_delete: :cascade }, type: :uuid
      t.string :name, null: false
      t.string :kind, null: false
      t.date :date
      t.string :person_key
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end

    add_index :forecast_milestones, %i[forecast_plan_id kind]
    add_index :forecast_milestones, %i[forecast_plan_id date]
  end
end
