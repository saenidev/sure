# frozen_string_literal: true

module Forecasts
  # Forecast V2 typed assumption editor endpoints (slice C7).
  #
  #   GET /forecast/assumptions/:id/edit  ->  EditorPrefillReadModel JSON
  #
  # Answers the spec's "Editor Contracts" / "Inertia And JSON Endpoints" rule for
  # the editor-open path: this endpoint returns ONE EditorPrefillReadModel (B13)
  # typed payload for a single assumption — the form key, current values,
  # collapsed-section summaries, and validation metadata (the optimistic
  # lock_version for stale-edit detection) — and NOTHING else. It returns a typed
  # editor payload, NOT a full plan payload, chart series, or projection-result
  # bodies (spec "EditorPrefillReadModel": "Other assumptions, chart series,
  # projection result bodies" must NOT be included).
  #
  # Opening the editor preserves plan/period/scenario context: those live entirely
  # in the client workspace store (useForecastWorkspace) and are untouched by this
  # read — the drawer composes over the existing workspace, so the selected period
  # and scenario stack survive the open/close.
  #
  # Read-model discipline (spec "Read Model Contracts"): the payload is built from
  # a single already-loaded Forecasts::Assumption row. The read model never calls
  # the engine, never enqueues recompute, never mutates records, and never parses
  # any projection-result JSON. This endpoint runs no projection math and opens a
  # drawer over an already-open workspace, so it does NOT load-or-create the plan
  # or ensure a cache (that is the /forecast show path) — it is a tight,
  # single-record read.
  #
  # Family scoping: the assumption is resolved through Current.family (never a
  # family_id from params), so an assumption belonging to another family is a 404,
  # never a leak.
  #
  # Gating: served only when the V2 feature check passes for the family, matching
  # the canonical /forecast V2 surface. Otherwise 404 (the V1 surface owns no such
  # JSON endpoint).
  class AssumptionsController < Forecasts::BaseController
    def edit
      return head(:not_found) unless forecast_v2_enabled?

      assumption = Current.family.forecast_assumptions.find_by(id: params[:id])
      return head(:not_found) if assumption.nil?

      render json: Forecasts::EditorPrefillReadModel.new(
        assumption: assumption,
        scenario_layer_id: scenario_layer_id_for(assumption)
      ).to_h
    end

    private
      def forecast_v2_enabled?
        Forecasts::V2Flag.enabled_for?(family: Current.family, user: Current.user)
      end

      # The scenario layer this assumption is being edited in, when the edit was
      # opened from a scenario-scoped card. The MVP edits baseline assumptions, so
      # this is nil unless the client passes a layer it already knows from the
      # open workspace (it is never trusted to widen family scope — the assumption
      # is already family-resolved above).
      def scenario_layer_id_for(_assumption)
        params[:scenario_layer_id].presence
      end
  end
end
