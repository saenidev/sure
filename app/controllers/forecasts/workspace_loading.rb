# frozen_string_literal: true

module Forecasts
  # Shared, family-scoped workspace-loading seam for the Forecast V2 surfaces.
  #
  # It is the ONE place that turns "this family opened /forecast" into the records
  # the V2 read models render from:
  #
  #   1. load-or-create the family's default plan (B10 DefaultPlanBuilder,
  #      idempotent: reopening /forecast never duplicates the plan), then
  #   2. ensure a CURRENT projection cache exists for the plan's live scenario
  #      stack, building one through the recompute coordinator (B12) only when it
  #      is missing — never running projection math inline, and never on a warm
  #      load that already has a fresh cache.
  #
  # The first-viewport prop assembly (`forecast_v2_workspace_props`) preloads the
  # plan, assumptions, current cache, and its indexed period/trace rows in a fixed
  # number of queries, then hands those already-loaded rows to the per-surface
  # read models (B13). No read model is allowed to call the engine, enqueue
  # recompute, or query per card / per issue / per trace, so the first-viewport
  # load stays within the spec's "Query And Data-Loading Budgets" (<= 35 SQL).
  #
  # The run/as-of date is threaded explicitly from the request boundary
  # (`forecast_as_of`) into the plan + snapshot builders so nothing downstream
  # reads Date.current (spec: thread the run/as-of date explicitly).
  #
  # Family scoping: every load is anchored to `Current.family`; this concern never
  # trusts a family_id from params, props, or payloads.
  module WorkspaceLoading
    extend ActiveSupport::Concern

    private
      # Returns the typed first-viewport props for the open plan, one region per
      # read model (spec "Inertia And JSON Endpoints" initial props, "First
      # Viewport Contract"). Every region is built from already-loaded rows.
      def forecast_v2_workspace_props
        plan = load_or_create_forecast_plan
        cache = ensure_current_projection_cache(plan)

        assumptions = plan.forecast_assumptions.to_a
        periods = cache ? cache.forecast_projection_periods.ordered.to_a : []
        selected_period = periods.first
        selected_traces = selected_period ? traces_for(cache, selected_period) : []
        active_ids = selected_period ? Array(selected_period.active_assumption_ids) : []

        {
          plan: Forecasts::PlanReadModel.new(plan: plan, cache: cache).to_h,
          band: Forecasts::ProjectionBandReadModel.new(cache: cache, periods: periods).to_h,
          selectedPeriod: selected_period_props(selected_period, selected_traces, cache),
          assumptionGroups: Forecasts::AssumptionGroupReadModel.new(
            assumptions: assumptions, active_assumption_ids: active_ids
          ).to_h,
          issues: issue_props(cache),
          freshness: freshness_props(cache)
        }
      end

      # Load-or-create the family's single active default plan. Idempotent: the
      # builder reuses the existing active plan and never duplicates plans or
      # per-source assumptions on reopen (B10).
      def load_or_create_forecast_plan
        Forecasts::DefaultPlanBuilder.new(
          family: Current.family, as_of: forecast_as_of
        ).build
      end

      # The family's existing active plan WITHOUT triggering plan/assumption
      # derivation. Returned for read-only JSON surfaces (e.g. the selected-period
      # endpoint, C5) that operate on an already-open workspace and must stay
      # within a tight query budget — they never create or re-derive a plan. Nil
      # when the family has no V2 plan yet. Family-scoped: anchored to
      # Current.family, never a family_id from params.
      def load_existing_forecast_plan
        Current.family.forecast_plans.active.ordered.first
      end

      # Returns the current (non-superseded) fresh projection cache for the plan's
      # baseline scenario stack, building it through the recompute coordinator only
      # when none exists yet (cold load). A warm load with a fresh cache does NO
      # projection work. Projection math is reached ONLY through the coordinator —
      # the controller never calls the engine inline (spec "Controllers":
      # controllers must not run projection math inline except through the
      # recompute coordinator).
      def ensure_current_projection_cache(plan)
        existing = current_fresh_cache(plan)
        return existing if existing

        snapshot = Forecasts::SourceSnapshotBuilder.new(
          plan: plan, as_of: forecast_as_of
        ).build

        Forecasts::Projection::RecomputeCoordinator.new(
          plan: plan, source_snapshot: snapshot
        ).recompute

        current_fresh_cache(plan)
      end

      def current_fresh_cache(plan)
        plan.forecast_projection_caches.current.where(status: :fresh).order(finished_at: :desc).first
      end

      # The already-loaded trace rows for the seeded selected period (ordered by
      # the coordinator's stored display_order). One query for the whole period;
      # the read model adds none.
      def traces_for(cache, period)
        cache.forecast_projection_traces.for_period(period.period_key).ordered.to_a
      end

      # Selected-period seed for the default period. When there is no projected
      # period yet (cache still building), the client opens on a "select a period"
      # inspector state, so the seed is nil rather than a fabricated period.
      def selected_period_props(period, traces, cache)
        return nil if period.nil?

        Forecasts::SelectedPeriodReadModel.new(
          period: period, traces: traces, cache: cache
        ).to_h
      end

      # Privacy-safe issue summary list for the issue panel, built from the cache's
      # stored issue summary codes (NO per-issue query, spec "Render plan issues:
      # no per-issue queries"). Each code is shaped by the IssueReadModel so the
      # client renders localized, privacy-safe copy.
      def issue_props(cache)
        codes = cache&.issue_summary&.dig("codes") || {}
        codes.keys.map do |code|
          Forecasts::IssueReadModel.new(issue: {
            code: code,
            severity: "limited",
            source: "projection",
            message_key: "forecasts.issues.#{code}",
            display_name: code,
            actions: []
          }).to_h
        end
      end

      # Shell-level freshness for the freshness indicator, read straight off the
      # cache row (status + finished_at); "uncomputed" before the first cache.
      def freshness_props(cache)
        return { state: "uncomputed", projected_at: nil } if cache.nil?

        { state: cache.status, projected_at: cache.finished_at&.iso8601 }
      end

      # The run/as-of date threaded into the plan + snapshot builders. Resolved at
      # the request boundary so nothing downstream reads Date.current.
      def forecast_as_of
        @forecast_as_of ||= Date.current
      end
  end
end
