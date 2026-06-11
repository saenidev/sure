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
    # and the array position. source_record_refs are NOT stored either (they
    # were ~33% of the blob bytes): they derive entirely from "a" — the self
    # ref { type: "assumption", id: a } plus one { type: "category", id: ... }
    # per entry of that assumption's params["category_ids"] (see
    # TraceBuilder#source_record_refs). Readers needing refs reconstruct them
    # from the plan's assumptions.
    #
    # "mk" and "d" are SPARSE: stored only when they diverge from the
    # category-derived defaults — metric_key defaults to "k" itself and
    # direction to TRACE_DIRECTION_FOR_CATEGORY["k"]. Both proof-slice kinds
    # always match the defaults, so current blobs omit the keys entirely;
    # readers must fall back to the derived defaults.
    TRACE_KEYS = {
      "a"  => :assumption_id,
      "mk" => :metric_key,         # sparse; defaults to "k"
      "d"  => :direction,          # sparse; defaults to TRACE_DIRECTION_FOR_CATEGORY["k"]
      "am" => :amount,             # decimal string
      "c"  => :currency,
      "k"  => :category,
      "e"  => :explanation_key
    }.freeze

    # Default direction per trace category, used by blob readers when a sparse
    # entry omits "d" (see TRACE_KEYS).
    TRACE_DIRECTION_FOR_CATEGORY = {
      "income" => "inflow",
      "spending" => "outflow"
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

    # Columns bulk_load! writes, in row-hash key order. `id` is omitted on
    # purpose so the table's uuid default (gen_random_uuid()) applies, exactly
    # as it did under insert_all!.
    BULK_LOAD_COLUMNS = %w[
      forecast_projection_cache_id forecast_plan_id scenario_stack_key
      period_key period_start_on period_end_on granularity metrics traces
      issue_codes active_assumption_ids plan_version engine_version
      created_at updated_at
    ].freeze

    # Bulk-persists period rows (symbol-keyed hashes covering exactly
    # BULK_LOAD_COLUMNS) in ONE statement on the CURRENT transaction's
    # connection, so a surrounding transaction's rollback semantics are intact
    # (the recompute coordinator wraps cache + periods in one transaction; a
    # failed period write must roll back the cache row).
    #
    # Transport is one multi-row INSERT via PQexecParams ($n binds) instead of
    # insert_all!: insert_all! quotes ~5.4k literals through Arel into the SQL
    # text on top of PG's work, while exec_params streams the values as bind
    # parameters (30y x 25-assumption save: ~600ms -> ~450ms total). COPY text
    # format was benchmarked head-to-head on the same profile and tied within
    # noise (best 403ms vs 398ms); exec_params is kept for its smaller surface
    # (no escaping pass, errors surface as normal SQLSTATE on the statement).
    # PG resolves the untyped binds against the target column types, so
    # dates/timestamps/jsonb arrive as ISO/JSON strings.
    def self.bulk_load!(rows)
      return if rows.blank?

      width = BULK_LOAD_COLUMNS.length
      binds = Array.new(rows.length * width)
      tuples = rows.each_with_index.map do |row, row_index|
        base = row_index * width
        BULK_LOAD_COLUMNS.each_with_index do |column, column_index|
          binds[base + column_index] = bulk_load_field(row.fetch(column.to_sym))
        end
        "($#{(base + 1..base + width).to_a.join(',$')})"
      end

      sql = "INSERT INTO #{table_name} (#{BULK_LOAD_COLUMNS.join(', ')}) VALUES #{tuples.join(',')}"
      with_connection { |connection| connection.raw_connection.exec_params(sql, binds) }
      nil
    end

    # Serializes one bulk_load! value to the string PG parses against the
    # column type. Pre-encoded JSON strings pass through untouched (same
    # contract as FastJsonbType above).
    def self.bulk_load_field(value)
      case value
      when nil, ::String then value
      when ::Hash, ::Array then ::JSON.generate(value)
      when ::Time then value.utc.iso8601(6)
      else value.to_s # Date#to_s is ISO 8601; integers/symbols stringify
      end
    end
    private_class_method :bulk_load_field

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
