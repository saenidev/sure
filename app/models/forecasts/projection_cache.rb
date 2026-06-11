# frozen_string_literal: true

# Forecast V2 mutable projection cache: the current computed result for a plan +
# scenario stack + source snapshot + plan version + engine version. Replaceable;
# the recompute coordinator writes it. Family-scoped through its plan.
module Forecasts
  class ProjectionCache < ApplicationRecord
    self.table_name = "forecast_projection_caches"

    belongs_to :forecast_plan,
      class_name: "Forecasts::Plan",
      inverse_of: :forecast_projection_caches
    belongs_to :forecast_source_snapshot,
      class_name: "Forecasts::SourceSnapshot",
      inverse_of: :forecast_projection_caches,
      optional: true

    has_many :forecast_projection_periods,
      class_name: "Forecasts::ProjectionPeriod",
      foreign_key: :forecast_projection_cache_id,
      inverse_of: :forecast_projection_cache,
      dependent: :destroy

    enum :status, {
      fresh: "fresh",
      stale: "stale",
      recomputing: "recomputing",
      failed: "failed",
      superseded: "superseded"
    }, default: :recomputing, validate: true, scopes: false

    validates :plan_version, :scenario_stack_key, :scenario_stack_hash,
      :source_snapshot_hash, :engine_version, presence: true

    scope :current, -> { where.not(status: :superseded) }
  end
end
