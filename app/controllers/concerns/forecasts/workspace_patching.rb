# frozen_string_literal: true

module Forecasts
  # Shared post-save pipeline for workspace endpoints that mutate plan
  # assumptions (drawer auto-saves, resync accepts): Amendment A
  # compute-synchronous / persist-async. Pure move out of
  # Forecasts::AssumptionsController — behavior is pinned by
  # test/controllers/forecasts/assumptions_controller_test.rb.
  #
  # Contract: the including controller sets @plan and @assumption before
  # calling any of these helpers.
  module WorkspacePatching
    extend ActiveSupport::Concern

    private
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

      # Enqueues the off-request cache write (the persist-async half of
      # Amendment A). No snapshot — reuse failed AND rebuild failed — means
      # there is nothing the job could persist.
      def enqueue_projection_persist(snapshot)
        return if snapshot.nil?

        ForecastProjectionPersistJob.perform_later(
          @plan.id, snapshot.id, @plan.current_plan_version, Date.current
        )
      end

      # The drawer's auto-submit controller (and the undo toast) read the
      # fresh optimistic-lock token from this header — update! already bumped
      # lock_version in memory, so no reload is needed.
      def write_assumption_lock_header
        response.set_header("X-Forecast-Assumption-Lock", @assumption.lock_version.to_s)
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
      # render from the last good persisted cache instead. When NEITHER exists
      # (compute failed before any cache was ever persisted) there is nothing
      # to refresh — the save itself succeeded, so the projection-region and
      # issues streams are omitted and only the card + lock token go out.
      def workspace_patch_streams(result, snapshot: nil)
        plan = @plan.reload
        assumption = @assumption.reload

        if result
          island = Forecasts::WorkspaceIsland.from_result(
            plan: plan, result: result,
            snapshot: snapshot || last_good_cache&.forecast_source_snapshot
          )
          issues = result.issues.map(&:code).tally
        elsif (cache = last_good_cache)
          island = Forecasts::WorkspaceIsland.from_cache(plan: plan, cache: cache)
          issues = (cache.issue_summary || {}).fetch("codes", {})
        end

        streams = []
        if island
          streams << turbo_stream.update(
            "forecast_projection_region",
            partial: "forecasts/projection_region",
            locals: { plan: plan, island: island }
          )
        end
        streams << turbo_stream.replace(
          helpers.dom_id(assumption),
          partial: "forecasts/assumption_card",
          locals: { assumption: assumption }
        )
        if island
          streams << turbo_stream.update(
            "forecast_issues",
            partial: "forecasts/workspace_issues",
            locals: { issues: issues }
          )
        end
        streams << turbo_stream.replace(
          "forecast_drawer_lock",
          html: helpers.hidden_field_tag(
            "assumption[expected_lock_version]", assumption.lock_version, id: "forecast_drawer_lock"
          )
        )
        streams
      end
  end
end
