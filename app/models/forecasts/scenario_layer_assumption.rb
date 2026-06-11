# frozen_string_literal: true

# Forecast V2 join row linking a scenario layer's behavior (add/override/disable/
# fork) to an assumption. Family-scoped through its layer's plan.
module Forecasts
  class ScenarioLayerAssumption < ApplicationRecord
    self.table_name = "forecast_scenario_layer_assumptions"

    belongs_to :forecast_scenario_layer,
      class_name: "Forecasts::ScenarioLayer",
      inverse_of: :forecast_scenario_layer_assumptions
    belongs_to :forecast_assumption,
      class_name: "Forecasts::Assumption",
      inverse_of: :forecast_scenario_layer_assumptions

    enum :operation, {
      add: "add",
      override: "override",
      disable: "disable",
      fork: "fork"
    }, validate: true, scopes: false

    scope :enabled, -> { where(enabled: true) }
  end
end
