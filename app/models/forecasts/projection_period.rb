# frozen_string_literal: true

# Forecast V2 relational read row for one projected period (day/month/year).
# Powers selected-period updates, metric strips, and first-viewport reads without
# parsing full projection JSON. Family-scoped through its plan.
module Forecasts
  class ProjectionPeriod < ApplicationRecord
    self.table_name = "forecast_projection_periods"

    belongs_to :forecast_projection_cache,
      class_name: "Forecasts::ProjectionCache",
      inverse_of: :forecast_projection_periods
    belongs_to :forecast_plan,
      class_name: "Forecasts::Plan",
      inverse_of: :forecast_projection_periods

    enum :granularity, {
      day: "day",
      month: "month",
      year: "year"
    }, validate: true, scopes: false

    validates :scenario_stack_key, :period_key, :period_start_on, :period_end_on,
      :plan_version, :engine_version, presence: true

    scope :for_stack, ->(key) { where(scenario_stack_key: key) }
    scope :ordered, -> { order(:period_start_on) }
  end
end
