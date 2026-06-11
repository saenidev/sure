# frozen_string_literal: true

module Forecasts
  # Plan-workspace assumption editing. Family-scoped through Current.family on
  # every query — an id from another family is a 404, never a 403 leak.
  #
  # update is the auto-save endpoint (spec §4.6/§11, plan Amendment A:
  # compute-synchronous, persist-async): validate via the kind's typed form,
  # persist + bump the plan version in one transaction, run the engine IN
  # MEMORY (anchored at today, §10, reusing the current cache's source
  # snapshot — a save edits assumptions, not source data), respond with ONE
  # Turbo Stream that patches the projection region (which embeds the island),
  # the card, and the issue banner, then enqueue ForecastProjectionPersistJob
  # AFTER the transaction to write the cache off-request. A failed compute
  # keeps the save and leaves the last good projection on screen — never a
  # raw error.
  class AssumptionsController < ApplicationController
    before_action :set_assumption

    def edit
      @form_partial = "forecasts/assumptions/form_#{@assumption.kind}"
    end

    def update
      form_class = Forecasts::Assumptions::Registry.form_class_for(@assumption.kind)
      return head :unprocessable_entity if form_class.nil?

      form = form_class.new(
        family: Current.family, plan: @plan, params: assumption_params, assumption: @assumption
      )

      return render_form_errors(form) unless form.valid?

      Forecasts::Plan.transaction do
        @assumption.update!(form.assumption_attributes)
        @plan.increment!(:current_plan_version)
      end

      snapshot = save_snapshot
      result = compute_projection(snapshot)
      if snapshot
        ForecastProjectionPersistJob.perform_later(
          @plan.id, snapshot.id, @plan.current_plan_version, Date.current
        )
      end

      render turbo_stream: workspace_patch_streams(result)
    end

    private
      def set_assumption
        @assumption = Current.family.forecast_assumptions.find_by(id: params[:id])
        head :not_found if @assumption.nil?
        @plan = @assumption&.forecast_plan
      end

      def assumption_params
        params.require(:assumption).permit(
          :name, :amount, :currency, :person_key, :gross_or_net, :frequency,
          :growth_policy, :growth_rate, :net_ratio, :cash_account_id,
          :inflation_policy, :inflation_rate, :actualization_policy,
          :starts_on, :ends_on, :starts_at_milestone_id, :ends_at_milestone_id,
          :expected_lock_version, category_ids: []
        )
      end

      # Amendment A snapshot reuse: the in-memory compute and the persist job
      # both run over the current cache's snapshot (rebuilding one costs
      # ~250ms of derivation queries — the whole save budget). Falls back to
      # building a snapshot only when no cache exists yet.
      def save_snapshot
        last_good_cache&.forecast_source_snapshot ||
          Forecasts::SourceSnapshotBuilder.new(plan: @plan, as_of: Date.current).build
      rescue StandardError => e
        Rails.logger.error("forecast snapshot reuse failed plan=#{@plan.id} #{e.class}")
        nil
      end

      # In-memory engine run, no persistence (RecomputeCoordinator#compute).
      # nil on failure: the save is kept and the streams fall back to the last
      # good cache.
      def compute_projection(snapshot)
        return nil if snapshot.nil?

        Forecasts::Projection::RecomputeCoordinator
          .new(plan: @plan, source_snapshot: snapshot, anchor_on: Date.current)
          .compute
      rescue StandardError => e
        Rails.logger.error("forecast recompute failed plan=#{@plan.id} #{e.class}")
        nil
      end

      def last_good_cache
        @plan.forecast_projection_caches.current.order(created_at: :desc).first
      end

      # The shared patch set. turbo_stream.UPDATE for the two wrapper divs —
      # their ids live on the page shell, so updates keep the targets alive
      # across saves (a replace would strip the id after the first save and
      # every later stream would silently no-op). REPLACE for the card (its
      # partial root carries its own dom_id). Always ends by re-threading the
      # drawer's lock token so an open drawer can keep auto-saving.
      #
      # `result` is the fresh in-memory engine Result (Amendment A); when it is
      # nil (failed compute, or the 409 restream) the island and issue banner
      # render from the last good persisted cache instead.
      def workspace_patch_streams(result)
        plan = @plan.reload
        assumption = @assumption.reload

        if result
          island = Forecasts::WorkspaceIsland.from_result(plan: plan, result: result)
          issues = result.issues.map(&:code).tally
        else
          cache = last_good_cache
          island = Forecasts::WorkspaceIsland.from_cache(plan: plan, cache: cache)
          issues = (cache&.issue_summary || {}).fetch("codes", {})
        end

        [
          turbo_stream.update(
            "forecast_projection_region",
            partial: "forecasts/projection_region",
            locals: { plan: plan, island: island }
          ),
          turbo_stream.replace(
            helpers.dom_id(assumption),
            partial: "forecasts/assumption_card",
            locals: { assumption: assumption }
          ),
          turbo_stream.update(
            "forecast_issues",
            partial: "forecasts/workspace_issues",
            locals: { issues: issues }
          ),
          turbo_stream.replace(
            "forecast_drawer_lock",
            html: helpers.hidden_field_tag(
              "assumption[expected_lock_version]", assumption.lock_version, id: "forecast_drawer_lock"
            )
          )
        ]
      end

      # Validation failure: 422 + re-render the drawer form (update keeps the
      # #forecast_drawer_form wrapper alive) with errors. A stale lock — BaseForm
      # puts code "stale_version" on :base — is a 409, and per spec §4.6 the
      # server state wins VISIBLY: the workspace patch streams ride along so the
      # page and the drawer's lock token reflect the server.
      def render_form_errors(form)
        @form_partial = "forecasts/assumptions/form_#{@assumption.kind}"
        stale = form.error_codes_for(:base).include?("stale_version")
        @assumption.reload if stale

        streams = [
          turbo_stream.update(
            "forecast_drawer_form",
            partial: @form_partial,
            locals: { assumption: @assumption, plan: @plan, form_object: form }
          )
        ]
        streams.concat(workspace_patch_streams(nil)) if stale

        render status: (stale ? :conflict : :unprocessable_entity), turbo_stream: streams
      end
  end
end
