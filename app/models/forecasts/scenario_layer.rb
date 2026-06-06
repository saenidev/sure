# frozen_string_literal: true

# Forecast V2 scenario layer. A stack of layers over the base plan produces a
# scenario projection. Family-scoped through its plan.
module Forecasts
  class ScenarioLayer < ApplicationRecord
    self.table_name = "forecast_scenario_layers"

    belongs_to :forecast_plan,
      class_name: "Forecasts::Plan",
      inverse_of: :forecast_scenario_layers
    belongs_to :base_layer,
      class_name: "Forecasts::ScenarioLayer",
      inverse_of: :derived_layers,
      optional: true

    has_many :derived_layers,
      class_name: "Forecasts::ScenarioLayer",
      foreign_key: :base_layer_id,
      inverse_of: :base_layer,
      dependent: :nullify
    has_many :forecast_scenario_layer_assumptions,
      class_name: "Forecasts::ScenarioLayerAssumption",
      foreign_key: :forecast_scenario_layer_id,
      inverse_of: :forecast_scenario_layer,
      dependent: :destroy
    has_many :forecast_assumptions,
      through: :forecast_scenario_layer_assumptions,
      source: :forecast_assumption

    enum :status, {
      active: "active",
      disabled: "disabled",
      archived: "archived"
    }, default: :active, validate: true, scopes: false

    validates :name, presence: true

    scope :ordered, -> { order(:position, :created_at) }
  end
end
