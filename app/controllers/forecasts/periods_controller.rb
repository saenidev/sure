# frozen_string_literal: true

module Forecasts
  # Forecast V2 selected-period JSON read-model endpoint (slice C5).
  #
  #   GET /forecast/periods/:period_key  ->  SelectedPeriodReadModel JSON
  #
  # Answers exactly the spec's "Inertia And JSON Endpoints" rule for the
  # selected-period path: this endpoint returns the SelectedPeriodReadModel (B13)
  # typed UI payload ONLY after a SETTLED selection, a client cache miss, or an
  # explicit refresh. Pointer hover/scrub over the chart issues NO network and so
  # never reaches here — the client (usePeriodPayloadCache, C5) serves those from
  # its preloaded seed + local cache and only fetches this endpoint on a settled
  # cache miss (debounced).
  #
  # Read-model discipline (spec "Read Model Contracts"): the payload is built from
  # the indexed Forecasts::ProjectionPeriod row plus its Forecasts::ProjectionTrace
  # rows — it NEVER parses the full projection-result JSON and never returns raw
  # engine internals (packets, snapshots, result hashes, trace-graph dumps). The
  # endpoint never runs projection math, never enqueues recompute, and never
  # mutates records.
  #
  # Family scoping: the plan, current cache, and period are all resolved through
  # Current.family (Forecasts::BaseController). A family_id in params is ignored;
  # a period belonging to another family — or one this family has not projected —
  # is a 404, never a leak.
  #
  # Gating: served only when the V2 feature check passes for the family, matching
  # the canonical /forecast V2 surface. Otherwise 404 (the V1 surface owns no such
  # JSON endpoint).
  class PeriodsController < Forecasts::BaseController
    def show
      return head(:not_found) unless forecast_v2_enabled?

      plan = load_existing_forecast_plan
      return head(:not_found) if plan.nil?

      cache = current_fresh_cache(plan)
      return head(:not_found) if cache.nil?

      period = cache.forecast_projection_periods.for_stack(cache.scenario_stack_key)
        .find_by(period_key: params[:period_key])
      return head(:not_found) if period.nil?

      render json: Forecasts::SelectedPeriodReadModel.new(
        period: period,
        traces: traces_for(cache, period),
        cache: cache
      ).to_h
    end

    private
      def forecast_v2_enabled?
        Forecasts::V2Flag.enabled_for?(family: Current.family, user: Current.user)
      end
  end
end
