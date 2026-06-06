# frozen_string_literal: true

# Forecast V2 relational trace row explaining one flow contributing to a period
# metric. Powers explanation panels without parsing full projection JSON. The
# assumption reference is a soft link (no DB FK) because traces may outlive the
# assumption rows they describe.
module Forecasts
  class ProjectionTrace < ApplicationRecord
    self.table_name = "forecast_projection_traces"

    belongs_to :forecast_projection_cache,
      class_name: "Forecasts::ProjectionCache",
      inverse_of: :forecast_projection_traces
    belongs_to :assumption,
      class_name: "Forecasts::Assumption",
      optional: true

    enum :granularity, {
      day: "day",
      month: "month",
      year: "year"
    }, validate: true, scopes: false

    validates :period_key, :metric_key, :trace_kind, presence: true

    scope :for_period, ->(period_key) { where(period_key: period_key) }
    scope :ordered, -> { order(:display_order) }
  end
end
