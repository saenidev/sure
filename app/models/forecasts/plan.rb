# frozen_string_literal: true

# Forecast V2 editable plan root. Family-scoped and namespaced under the
# pluralized `Forecasts::` namespace so the V1 `Forecast::` service classes
# coexist untouched. Pure persistence: associations, enums, scopes, optimistic
# locking only — the projection engine is pure and lives elsewhere.
module Forecasts
  class Plan < ApplicationRecord
    self.table_name = "forecast_plans"

    belongs_to :family

    has_many :forecast_milestones,
      class_name: "Forecasts::Milestone",
      foreign_key: :forecast_plan_id,
      inverse_of: :forecast_plan,
      dependent: :destroy
    has_many :forecast_assumptions,
      class_name: "Forecasts::Assumption",
      foreign_key: :forecast_plan_id,
      inverse_of: :forecast_plan,
      dependent: :destroy
    has_many :forecast_scenario_layers,
      class_name: "Forecasts::ScenarioLayer",
      foreign_key: :forecast_plan_id,
      inverse_of: :forecast_plan,
      dependent: :destroy
    has_many :forecast_source_snapshots,
      class_name: "Forecasts::SourceSnapshot",
      foreign_key: :forecast_plan_id,
      inverse_of: :forecast_plan,
      dependent: :destroy
    has_many :forecast_projection_caches,
      class_name: "Forecasts::ProjectionCache",
      foreign_key: :forecast_plan_id,
      inverse_of: :forecast_plan,
      dependent: :destroy
    has_many :forecast_projection_periods,
      class_name: "Forecasts::ProjectionPeriod",
      foreign_key: :forecast_plan_id,
      inverse_of: :forecast_plan,
      dependent: :destroy

    enum :status, { active: "active", archived: "archived" }, default: :active, validate: true, scopes: true

    validates :name, :horizon_start_on, :horizon_end_on, :reporting_currency, presence: true

    scope :ordered, -> { order(created_at: :desc) }
  end
end
