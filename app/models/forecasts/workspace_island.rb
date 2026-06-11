# frozen_string_literal: true

module Forecasts
  # Builds the workspace's single JSON data island (spec §4 contract, parts a+b;
  # part c "packet lite" arrives with the preview engine). Everything the chart,
  # metric column, lens tabs, scrubber, and inspector need ships here ONCE, so
  # scrubbing and lens switching are zero-network.
  #
  # Two sources, one byte-identical island (plan Amendment A):
  # - `.from_cache(plan:, cache:)`  — GET path, reads persisted period rows.
  # - `.from_result(plan:, result:)` — save path, reads the in-memory engine
  #   Result (compute-synchronous, persist-async: the Turbo Stream response
  #   renders from the Result while ForecastProjectionPersistJob writes the
  #   cache off-request).
  # Both normalize to identical period tuples (key, ISO start date, metric
  # decimal strings, sorted active-assumption ids), so the serialized JSON for
  # the same projection is byte-identical regardless of source (tested).
  #
  # Keys are deliberately terse — the island covers up to 361 periods and must
  # stay under the 150KB budget (enforced by test):
  #   periods[]: k=period key, s=start date,
  #              m={nw net_worth, lc liquid_cash, inc income, sp spending,
  #                 db debt_balance, pv portfolio_value, rd runway_days},
  #              aa=active assumption refs as ORDINAL INDEXES into the
  #                 assumptions list (UUID arrays per period would cost
  #                 ~350KB alone at 25 assumptions x 361 periods)
  #   assumptions: ordered list of {id, name, kind, group, icon}
  class WorkspaceIsland
    METRIC_KEYS = {
      nw: "net_worth", lc: "liquid_cash", inc: "income", sp: "spending",
      db: "debt_balance", pv: "portfolio_value", rd: "runway_days"
    }.freeze

    # Registry kinds -> rail group (the registry orders groups; the island only
    # labels them so the client can group cards consistently with the rail).
    GROUP_FOR_KIND = {
      "salary" => "income",
      "living_expense" => "expenses"
    }.freeze

    # GET path: monthly period tuples from the persisted cache rows.
    def self.from_cache(plan:, cache:)
      tuples = cache.forecast_projection_periods
        .where(granularity: "month")
        .order(:period_start_on)
        .map do |period|
          metrics = period.metrics || {}
          {
            key: period.period_key,
            starts_on: period.period_start_on.iso8601,
            metrics: METRIC_KEYS.transform_values { |name| metrics[name] },
            active_assumption_ids: period.active_assumption_ids || []
          }
        end

      new(plan: plan, period_tuples: tuples)
    end

    # Save path: monthly period tuples from the in-memory engine Result.
    # Result periods carry symbol-keyed metrics with the SAME decimal strings
    # the cache rows store (Metrics#to_h is the single producer for both), and
    # active assumption ids derive from the trace rows grouped by period —
    # compact/unique/sorted exactly as RecomputeCoordinator persists them.
    def self.from_result(plan:, result:)
      trace_rows = result.trace_rows || result.traces
      ids_by_period = trace_rows.group_by(&:period_key).transform_values do |period_traces|
        period_traces.map(&:assumption_id).compact.uniq.sort_by(&:to_s)
      end

      tuples = result.periods
        .select { |period| period[:granularity].to_s == "month" }
        .sort_by { |period| period[:starts_on].to_s }
        .map do |period|
          metrics = period[:metrics] || {}
          {
            key: period[:key],
            starts_on: period[:starts_on].to_s, # engine emits ISO 8601 strings
            metrics: METRIC_KEYS.transform_values { |name| metrics[name.to_sym] },
            active_assumption_ids: ids_by_period.fetch(period[:key], [])
          }
        end

      new(plan: plan, period_tuples: tuples)
    end

    def initialize(plan:, period_tuples:)
      @plan = plan
      @period_tuples = period_tuples
    end
    private_class_method :new

    def to_h
      entries = assumption_entries
      index_by_id = entries.each_with_index.to_h { |entry, i| [ entry[:id], i ] }

      {
        plan: plan_section,
        periods: period_rows(index_by_id),
        assumptions: entries
      }
    end

    def to_json(*)
      to_h.to_json
    end

    private
      def plan_section
        {
          id: @plan.id,
          name: @plan.name,
          currency: @plan.reporting_currency,
          version: @plan.current_plan_version,
          lock_version: @plan.lock_version,
          horizon: { starts_on: @plan.horizon_start_on, ends_on: @plan.horizon_end_on }
        }
      end

      def period_rows(index_by_id)
        @period_tuples.map do |tuple|
          {
            k: tuple[:key],
            s: tuple[:starts_on],
            m: tuple[:metrics],
            aa: tuple[:active_assumption_ids].filter_map { |id| index_by_id[id] }
          }
        end
      end

      def assumption_entries
        @plan.forecast_assumptions
          .where.not(status: %w[disabled archived])
          .order(:created_at)
          .map do |a|
            {
              id: a.id,
              name: a.name,
              kind: a.kind,
              group: GROUP_FOR_KIND.fetch(a.kind, "other"),
              icon: Forecasts::Assumptions::Registry.icon_for(a.kind)
            }
          end
      end
  end
end
