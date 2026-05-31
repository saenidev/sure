class CreateForecastBudgetPlans < ActiveRecord::Migration[7.2]
  def change
    create_table :forecast_budget_plans, id: :uuid do |t|
      t.references :family, null: false, foreign_key: true, type: :uuid
      t.references :forecast_scenario, null: false, foreign_key: { on_delete: :cascade }, type: :uuid, index: { unique: true }
      t.date :base_period_start_on, null: false
      t.date :horizon_start_on, null: false
      t.date :horizon_end_on, null: false
      t.string :currency, null: false
      t.jsonb :activation_metadata, null: false, default: {}
      t.jsonb :dependency_metadata, null: false, default: {}
      t.jsonb :source_metadata, null: false, default: {}
      t.timestamps
    end

    add_index :forecast_budget_plans, %i[family_id horizon_start_on horizon_end_on], name: "idx_forecast_budget_plans_family_horizon"

    create_table :forecast_budget_plan_amounts, id: :uuid do |t|
      t.references :family, null: false, foreign_key: true, type: :uuid
      t.references :forecast_budget_plan, null: false, foreign_key: { on_delete: :cascade }, type: :uuid
      t.references :category, foreign_key: { on_delete: :cascade }, type: :uuid
      t.date :period_start_on, null: false
      t.string :amount_type, null: false
      t.decimal :amount, precision: 19, scale: 4, null: false
      t.string :currency, null: false
      t.text :note
      t.jsonb :source_metadata, null: false, default: {}
      t.timestamps
    end

    add_index :forecast_budget_plan_amounts,
      "forecast_budget_plan_id, period_start_on, amount_type, COALESCE(category_id, '00000000-0000-0000-0000-000000000000'::uuid)",
      unique: true,
      name: "idx_forecast_budget_plan_amounts_unique_key"
    add_index :forecast_budget_plan_amounts, %i[family_id period_start_on], name: "idx_forecast_budget_plan_amounts_family_period"

    create_table :forecast_budget_templates, id: :uuid do |t|
      t.references :family, null: false, foreign_key: true, type: :uuid
      t.string :name, null: false
      t.text :description
      t.string :currency, null: false
      t.jsonb :source_metadata, null: false, default: {}
      t.timestamps
    end

    add_index :forecast_budget_templates, %i[family_id name], name: "idx_forecast_budget_templates_family_name"

    create_table :forecast_budget_template_amounts, id: :uuid do |t|
      t.references :family, null: false, foreign_key: true, type: :uuid
      t.references :forecast_budget_template, null: false, foreign_key: { on_delete: :cascade }, type: :uuid
      t.references :category, foreign_key: { on_delete: :cascade }, type: :uuid
      t.string :amount_type, null: false
      t.decimal :amount, precision: 19, scale: 4, null: false
      t.string :currency, null: false
      t.text :note
      t.jsonb :source_metadata, null: false, default: {}
      t.timestamps
    end

    add_index :forecast_budget_template_amounts,
      "forecast_budget_template_id, amount_type, COALESCE(category_id, '00000000-0000-0000-0000-000000000000'::uuid)",
      unique: true,
      name: "idx_forecast_budget_template_amounts_unique_key"
  end
end
