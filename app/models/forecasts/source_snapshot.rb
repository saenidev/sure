# frozen_string_literal: true

# Forecast V2 normalized snapshot of connected Sure data prepared for the engine.
# Replaceable cache input, not a user-editable planning object. Family-scoped
# both directly and through its plan.
module Forecasts
  class SourceSnapshot < ApplicationRecord
    self.table_name = "forecast_source_snapshots"

    belongs_to :forecast_plan,
      class_name: "Forecasts::Plan",
      inverse_of: :forecast_source_snapshots
    belongs_to :family

    has_many :forecast_projection_caches,
      class_name: "Forecasts::ProjectionCache",
      foreign_key: :forecast_source_snapshot_id,
      inverse_of: :forecast_source_snapshot,
      dependent: :nullify

    enum :freshness_state, {
      fresh: "fresh",
      stale: "stale",
      expired: "expired"
    }, default: :fresh, validate: true, scopes: false

    validates :source_snapshot_hash, :as_of, presence: true

    scope :for_hash, ->(hash) { where(source_snapshot_hash: hash) }
  end
end
