# frozen_string_literal: true

# Forecast V2 relational read row for one projected period (day/month/year).
# Powers selected-period updates, metric strips, and first-viewport reads without
# parsing full projection JSON. Family-scoped through its plan.
#
# Traces are still persisted per period (spec 3.2.2) — only the storage shape
# changed: instead of one relational row per trace, each period row embeds its
# explanation traces as a compact jsonb array in `traces` (9k inserts -> 361 on
# a 30-year save). The array is ordered (ledger order; array position IS the
# display order) and zero-amount traces are filtered before storage.
module Forecasts
  class ProjectionPeriod < ApplicationRecord
    self.table_name = "forecast_projection_periods"

    # Compact key map for one embedded trace entry in the `traces` jsonb array.
    # Keys are shortened to keep the stored blob (and its JSON serialization
    # cost on the synchronous save path) small. granularity, period_key, and
    # display_order are NOT stored per trace — they are implicit from the row
    # and the array position.
    TRACE_KEYS = {
      "a"  => :assumption_id,
      "mk" => :metric_key,
      "d"  => :direction,
      "am" => :amount,             # decimal string
      "c"  => :currency,
      "k"  => :category,
      "e"  => :explanation_key,
      "r"  => :source_record_refs
    }.freeze

    # Fast write codec for this row's jsonb columns. Serializing them happens
    # inside the synchronous save budget (361 rows × traces blob + metrics +
    # issue_codes + active_assumption_ids ≈ ~12k nodes), and the default
    # ActiveSupport::JSON encoder walks every node in Ruby; JSON.generate is the
    # C-extension encoder and produces identical bytes for these payloads (plain
    # arrays/hashes of ASCII strings — no HTML-entity escaping or unicode
    # normalization differences apply). A pre-generated JSON String passes
    # through untouched so the recompute coordinator can memoize per-trace-entry
    # JSON across the 361 period rows instead of re-encoding ~9k entries.
    class FastJsonbType < ActiveRecord::Type::Json
      def serialize(value)
        case value
        when nil then nil
        when ::String then value
        else ::JSON.generate(value)
        end
      end
    end

    attribute :traces, FastJsonbType.new
    attribute :metrics, FastJsonbType.new
    attribute :issue_codes, FastJsonbType.new
    attribute :active_assumption_ids, FastJsonbType.new

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
