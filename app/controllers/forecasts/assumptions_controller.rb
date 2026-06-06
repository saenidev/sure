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
    # The typed form object for an assumption kind is resolved through the single
    # Assumption Type Registry (Forecasts::Assumptions::Registry), not a private
    # per-kind constant. An unknown stored kind has no form and is rejected
    # (422) on the save path below.

    def edit
      return head(:not_found) unless forecast_v2_enabled?

      assumption = Current.family.forecast_assumptions.find_by(id: params[:id])
      return head(:not_found) if assumption.nil?

      render json: Forecasts::EditorPrefillReadModel.new(
        assumption: assumption,
        scenario_layer_id: scenario_layer_id_for(assumption)
      ).to_h
    end

    # PATCH /forecast/assumptions/:id — save one typed assumption (spec "Live
    # Recompute Model", "Save endpoints", "Patch budget", "Conflict Handling").
    #
    # Validates via the kind's typed form (plan-version + lock_version optimistic
    # checks), persists in a transaction + increments the plan version, recomputes
    # within budget (else enqueues ForecastRecomputeJob + marks recomputing), and
    # returns a TYPED changed-region payload (NOT a full workspace reload). A stale
    # plan version returns a conflict preserving editor/period/scenario context.
    def update
      return head(:not_found) unless forecast_v2_enabled?

      assumption = Current.family.forecast_assumptions.find_by(id: params[:id])
      return head(:not_found) if assumption.nil?

      plan = assumption.forecast_plan
      form_class = Forecasts::Assumptions::Registry.form_class_for(assumption.kind)
      return head(:unprocessable_entity) if form_class.nil?

      # Conflict: the plan moved past the version the editor observed. Reject
      # without overwriting and preserve the editor/period/scenario context.
      return render_plan_version_conflict(plan, assumption) if stale_plan_version?(plan)

      form = form_class.new(
        family: Current.family, plan: plan, params: assumption_params, assumption: assumption
      )
      return render_form_invalid(form) unless form.valid?

      cache = commit_and_recompute(plan, assumption, form)

      render json: changed_region_payload(plan, assumption, cache)
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

      # The raw typed-form input. family_id / id / controller routing keys are
      # never forwarded — the form only reads its own typed fields, and family
      # scope is already resolved through Current.family above.
      def assumption_params
        params.except(:controller, :action, :id, :format, :family_id).to_unsafe_h
      end

      # True when the plan version the editor observed (`plan_version` in the
      # patch) is older than the plan's live current_plan_version — a concurrent
      # commit moved the plan ahead (spec "Live Recompute Model": "Every patch
      # includes the plan version observed by the user").
      def stale_plan_version?(plan)
        observed = params[:plan_version]
        return false if observed.blank?

        observed.to_i < plan.current_plan_version
      end

      # Persist the edit + increment the plan version in ONE transaction, then run
      # recompute synchronously within budget, or commit "recomputing" + enqueue
      # the background job when over budget (spec "Live Recompute Model"). Returns
      # the current projection cache (fresh after a sync recompute, recomputing
      # when deferred).
      def commit_and_recompute(plan, assumption, form)
        Forecasts::Plan.transaction do
          assumption.update!(form.assumption_attributes)
          plan.increment!(:current_plan_version)
        end

        recompute(plan)
      end

      # Recompute through the coordinator (B12) — the only seam allowed to run
      # projection math. Synchronous for small plans (the proof slice); otherwise
      # mark the projection regions recomputing and hand the work to the keyed
      # background job (spec "Recompute Job Contract").
      #
      # The edit + version bump already committed in `commit_and_recompute`, so a
      # raise from the snapshot builder or the engine here must NOT surface as a
      # 500 over a committed plan version. Mirror the background job's contract
      # (spec "Live Recompute Model"; "Sensitive Data In Logs"): swallow the
      # failure, log IDs/counts/e.class ONLY (no message, no financial detail),
      # and fall back to the deferred path so the saved card returns with a
      # visible recomputing freshness state instead of a raw exception.
      def recompute(plan)
        snapshot = Forecasts::SourceSnapshotBuilder.new(plan: plan, as_of: forecast_as_of).build
        coordinator = Forecasts::Projection::RecomputeCoordinator.new(plan: plan, source_snapshot: snapshot)

        if coordinator.recompute_synchronously?
          coordinator.recompute(against_plan_version: plan.current_plan_version)
          current_fresh_cache(plan)
        else
          defer_recompute(plan)
        end
      rescue StandardError => e
        # IDs/counts/e.class only — never a message or financial detail (spec
        # "Sensitive Data In Logs"). The committed edit stands; hand the projection
        # work to the keyed background job, which carries the same swallow contract.
        Rails.logger.error(
          "Forecasts::AssumptionsController#recompute failed " \
          "plan=#{plan.id} family=#{plan.family_id} version=#{plan.current_plan_version}: #{e.class}"
        )
        defer_recompute(plan)
      end

      # Over-budget path: mark a recomputing cache for the new version (so the
      # workspace shows committed-card + recomputing-projection state) and enqueue
      # the keyed background job.
      def defer_recompute(plan)
        cache = mark_recomputing(plan)
        ForecastRecomputeJob.perform_later(
          forecast_plan_id: plan.id,
          family_id: plan.family_id,
          plan_version: plan.current_plan_version,
          as_of: forecast_as_of.iso8601
        )
        cache
      end

      # Records a recomputing projection cache for the committed plan version so
      # the freshness region reads "recomputing" until the background job
      # publishes a fresh result. Reuses the prior cache's scenario stack so the
      # token stays on the live baseline stack.
      def mark_recomputing(plan)
        prior = current_fresh_cache(plan)
        plan.forecast_projection_caches.create!(
          forecast_source_snapshot: prior&.forecast_source_snapshot,
          plan_version: plan.current_plan_version,
          scenario_stack_key: prior&.scenario_stack_key || "baseline",
          scenario_stack_hash: prior&.scenario_stack_hash || "pending",
          source_snapshot_hash: prior&.source_snapshot_hash || "pending",
          engine_version: prior&.engine_version || Forecasts::Projection::PacketBuilder::ENGINE_VERSION,
          status: :recomputing,
          started_at: Time.current,
          issue_summary: {}
        )
      end

      # The typed changed-region payload (spec "Patch budget"). Loads the seeded
      # selected period + its trace rows from the current cache (already indexed by
      # the coordinator) so the inspector/metric strip patch without a full reload.
      def changed_region_payload(plan, assumption, cache)
        period = seeded_period(cache)
        traces = period ? traces_for(cache, period) : []

        Forecasts::SavedAssumptionPatchReadModel.new(
          assumption: assumption.reload,
          plan: plan.reload,
          cache: cache,
          period: period,
          traces: traces
        ).to_h
      end

      # The default selected period for the current cache (the first projected
      # month). Nil when projection output is not ready (deferred recompute).
      def seeded_period(cache)
        return nil if cache.nil? || !cache.fresh?

        cache.forecast_projection_periods.for_stack(cache.scenario_stack_key).ordered.first
      end

      # 409 Conflict: a stale plan version. No overwrite; preserve the editor /
      # period / scenario context so the client can re-anchor (spec "Conflict
      # Handling": "Conflict responses must preserve the selected period, lens,
      # scenario stack, and editor context").
      def render_plan_version_conflict(plan, assumption)
        render(
          status: :conflict,
          json: {
            conflict: "stale_plan_version",
            context: {
              assumption_id: assumption.id,
              plan_version: plan.current_plan_version,
              lock_version: assumption.lock_version,
              scenario_layer_id: scenario_layer_id_for(assumption)
            }
          }
        )
      end

      # 422 (field-level form errors) or 409 (stale optimistic lock). A stale
      # lock_version keeps the editor open as a conflict; other errors are typed
      # field errors the client maps to localized copy (spec "Conflict Handling",
      # "Form object rules").
      def render_form_invalid(form)
        if form.error_codes_for(:base).include?("stale_version")
          return render(
            status: :conflict,
            json: { conflict: "stale_lock_version", context: {} }
          )
        end

        render status: :unprocessable_entity, json: { errors: field_errors(form) }
      end

      # Flattens the form's stable error codes into a field -> first-code map the
      # client localizes via forecasts.editor.errors.<code>.
      def field_errors(form)
        form.errors.attribute_names.index_with do |attribute|
          form.error_codes_for(attribute).first
        end
      end
  end
end
