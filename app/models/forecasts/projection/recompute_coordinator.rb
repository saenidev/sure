# frozen_string_literal: true

require "bigdecimal"

module Forecasts
  module Projection
    # Forecast V2 recompute coordinator. The single seam that turns an editable
    # plan + source snapshot into a persisted, keyed projection cache.
    #
    #   Forecasts::Projection::RecomputeCoordinator
    #     .new(plan:, source_snapshot:)
    #     .recompute
    #
    # Pipeline (spec "Recompute coordinator", "Recompute Job Contract"):
    #
    #   1. Build the engine packet (B11 PacketBuilder) — the last place models are
    #      touched.
    #   2. Call the pure engine (B7 Engine.call) — no ActiveRecord inside.
    #   3. Persist a Forecasts::ProjectionCache + indexed ProjectionPeriod rows +
    #      ProjectionTrace rows in ONE transaction, keyed by
    #      forecast_plan_id + plan_version + scenario_stack_hash +
    #      source_snapshot_hash + engine_version.
    #
    # The coordinator is NOT the engine: it owns persistence, key/version
    # management, cache invalidation, and the sync-vs-background decision. It does
    # NOT format UI strings or broadcast — those live in read models / controllers
    # (boundary table: "Recompute coordinator | Choosing sync/background
    # recompute, cache invalidation, broadcast/update behavior | Simulation
    # details").
    #
    # Versioning + stale-result protection (spec "Versioning rules", "Recompute
    # Job Contract"): a recompute publishes a current cache ONLY if the
    # plan_version it computed for still matches the plan's live
    # current_plan_version. A STALE result (older plan_version than the plan's
    # current version) writes nothing current and records a superseded marker — it
    # can never overwrite a newer plan version's cache.
    #
    # Coalescing + idempotency: duplicate work for the exact same key
    # (plan_version + scenario_stack_hash + source_snapshot_hash + engine_version)
    # coalesces onto the one existing current cache when its result hash is
    # unchanged. Publishing a new current cache marks any prior current cache for
    # the same plan + scenario stack as superseded, so there is at most one live
    # cache per scenario stack.
    #
    # Family scoping: the family is derived from the plan record, never from
    # caller params (the PacketBuilder enforces snapshot/plan/family ownership).
    class RecomputeCoordinator
      InvalidRecomputeInputError = Class.new(ArgumentError)

      # Plans at or under this period count recompute synchronously inside the
      # request/interaction budget. Larger plans are handed to a background job.
      # The proof slice's 36-month plan is comfortably under budget.
      SYNC_PERIOD_BUDGET = 60

      # Maps a pure-engine trace category onto the metric the trace explains. For
      # the proof slice income/spending traces explain the like-named metric.
      METRIC_KEY_FOR_CATEGORY = {
        "income" => "income",
        "spending" => "spending"
      }.freeze

      # Maps a trace category onto its direction when the value object omits one.
      # The value object already carries a direction; this is a defensive default.
      DIRECTION_FOR_CATEGORY = {
        "income" => "inflow",
        "spending" => "outflow"
      }.freeze

      attr_reader :plan, :source_snapshot, :family

      def initialize(plan:, source_snapshot:)
        raise InvalidRecomputeInputError, "plan is required" if plan.nil?
        raise InvalidRecomputeInputError, "source_snapshot is required" if source_snapshot.nil?

        @plan = plan
        @source_snapshot = source_snapshot
        @family = plan.family
      end

      # Builds the packet, runs the engine, and persists the keyed cache. Returns
      # the persisted Forecasts::ProjectionCache when published, a superseded
      # marker cache when the result is stale, or the coalesced existing cache
      # when the key already holds an identical fresh result.
      #
      # `against_plan_version` is the plan version the work was scheduled for
      # (the recompute job key). When omitted it defaults to the version the
      # packet was built from. The stale guard compares it to the plan's live
      # current_plan_version: an older value cannot publish over a newer one.
      def recompute(against_plan_version: nil)
        packet = build_packet
        target_version = against_plan_version || packet.plan[:version]

        # Stale-result protection BEFORE running the engine: if the plan has
        # already moved past the version this work targets, do not publish.
        return record_superseded(packet, target_version) if stale?(target_version)

        result = Forecasts::Projection::Engine.call(packet)

        persist(packet, result, target_version)
      end

      # True when the plan is small enough to recompute inline within the
      # interaction budget (spec "Allowed recompute strategies": server-side
      # synchronous recompute for small deterministic plans).
      def recompute_synchronously?
        projected_period_count <= SYNC_PERIOD_BUDGET
      end

      private
        def build_packet
          Forecasts::Projection::PacketBuilder.new(
            plan: plan,
            source_snapshot: source_snapshot
          ).build
        end

        # A target version is stale once the plan's live version has advanced past
        # it. The plan is reloaded so a concurrently committed edit is observed.
        def stale?(target_version)
          live_version > target_version.to_i
        end

        def live_version
          plan.reload.current_plan_version
        end

        # --- Persistence ----------------------------------------------------

        # Persists the cache, periods, and traces in one transaction and marks
        # prior current caches for the same plan + scenario stack as superseded.
        # The stale guard is re-checked INSIDE the transaction so a version bump
        # racing with this write cannot publish over a newer plan version.
        def persist(packet, result, target_version)
          outcome = nil

          Forecasts::ProjectionCache.transaction do
            if stale?(target_version)
              outcome = record_superseded(packet, target_version)
              next
            end

            existing = current_cache_for_key(packet)
            if coalesces?(existing, result)
              outcome = existing
              next
            end

            supersede_current_caches!(packet)
            cache = write_cache!(packet, result)
            write_periods!(cache, packet, result)
            write_traces!(cache, result)
            prune_replaced_caches!(packet, keep: cache)
            outcome = cache
          end

          outcome
        end

        # The current (non-superseded) cache for this exact key, if any.
        def current_cache_for_key(packet)
          key_scope(packet).current.first
        end

        # Idempotent coalescing: an existing fresh cache with the same result hash
        # is returned untouched. The same key recomputed with the same inputs
        # yields the same result hash, so duplicate work does not rewrite rows.
        def coalesces?(existing, result)
          existing&.fresh? && existing.projection_result_hash == result_hash(result)
        end

        # At most one current cache per plan + scenario stack. Marking by
        # scenario_stack_key (not the exact version key) ensures a newer version's
        # cache supersedes the prior version's live cache for the same stack.
        def supersede_current_caches!(packet)
          plan.forecast_projection_caches
            .current
            .where(scenario_stack_key: packet.scenario_stack[:key])
            .update_all(status: "superseded", updated_at: Time.current)
        end

        # Cache hygiene (spec §8): at most ONE cache row per scenario stack
        # survives a publish — the row just written. Auto-save bumps the plan
        # version on every settle, so without this hard delete the table grows by
        # ~361 period rows per keystroke-settle. Pinned snapshot rows (phase 8
        # adds pinned_at) will be excluded here when pinning exists.
        def prune_replaced_caches!(packet, keep:)
          plan.forecast_projection_caches
            .where(scenario_stack_key: packet.scenario_stack[:key])
            .where.not(id: keep.id)
            .delete_all
        end

        def write_cache!(packet, result)
          plan.forecast_projection_caches.create!(
            forecast_source_snapshot: source_snapshot,
            plan_version: packet.plan[:version],
            scenario_stack_key: packet.scenario_stack[:key],
            scenario_stack_hash: packet.scenario_stack_hash,
            source_snapshot_hash: packet.source_snapshot_hash,
            engine_version: packet.engine_version,
            projection_result_hash: result_hash(result),
            status: "fresh",
            started_at: started_at,
            finished_at: Time.current,
            issue_summary: issue_summary(result)
          )
        end

        # Bulk-persists period rows in one INSERT. insert_all skips AR callbacks/
        # validations: acceptable here because rows are derived verbatim from the
        # engine result (already validated value objects), and required because a
        # 30-year plan writes ~361 rows inside the save round-trip budget.
        def write_periods!(cache, packet, result)
          traces_by_period = result.traces.group_by(&:period_key)
          now = Time.current

          rows = result.periods.map do |period|
            period_traces = traces_by_period.fetch(period[:key], [])
            {
              forecast_projection_cache_id: cache.id,
              forecast_plan_id: plan.id,
              scenario_stack_key: packet.scenario_stack[:key],
              period_key: period[:key],
              period_start_on: period[:starts_on],
              period_end_on: period[:ends_on],
              granularity: period[:granularity],
              metrics: period[:metrics],
              issue_codes: issue_codes_for(result, period),
              active_assumption_ids: active_assumption_ids_for(period_traces),
              plan_version: packet.plan[:version],
              engine_version: packet.engine_version,
              created_at: now,
              updated_at: now
            }
          end

          Forecasts::ProjectionPeriod.insert_all!(rows) if rows.any?
        end

        # Bulk-persists traces, skipping zero-amount rows (spec §3.2.2: traces
        # exist to explain flows; a zero flow explains nothing and at 30y scale
        # zero rows dominate the table).
        def write_traces!(cache, result)
          now = Time.current

          rows = result.traces.each_with_index.filter_map do |trace, index|
            amount = BigDecimal(trace.amount.to_s)
            next if amount.zero?

            {
              forecast_projection_cache_id: cache.id,
              period_key: trace.period_key,
              granularity: "month",
              assumption_id: trace.assumption_id,
              source_type: trace.source_type,
              source_id: nil,
              metric_key: metric_key_for(trace),
              direction: trace.direction || DIRECTION_FOR_CATEGORY[trace.category],
              amount: amount,
              currency: trace.currency,
              category: trace.category,
              display_order: index,
              trace_kind: trace.category,
              explanation_key: trace.explanation_key,
              source_record_refs: source_record_refs_payload(trace),
              created_at: now,
              updated_at: now
            }
          end

          Forecasts::ProjectionTrace.insert_all!(rows) if rows.any?
        end

        # --- Stale / superseded marker --------------------------------------

        # A stale result writes no current cache. It records a superseded marker
        # cache (idempotently) so the ignored work is auditable without ever
        # overwriting a newer plan version (spec: "A stale job writes no current
        # cache and may only record a superseded/ignored instrumentation event").
        def record_superseded(packet, target_version)
          existing = plan.forecast_projection_caches.where(
            plan_version: target_version,
            scenario_stack_hash: packet.scenario_stack_hash,
            source_snapshot_hash: packet.source_snapshot_hash,
            engine_version: packet.engine_version,
            status: "superseded"
          ).first
          return existing if existing

          plan.forecast_projection_caches.create!(
            forecast_source_snapshot: source_snapshot,
            plan_version: target_version,
            scenario_stack_key: packet.scenario_stack[:key],
            scenario_stack_hash: packet.scenario_stack_hash,
            source_snapshot_hash: packet.source_snapshot_hash,
            engine_version: packet.engine_version,
            status: "superseded",
            started_at: started_at,
            finished_at: Time.current,
            error_code: "stale_plan_version",
            issue_summary: {}
          )
        end

        # --- Key + derived payloads -----------------------------------------

        # The full cache key scope: plan + plan_version + scenario_stack_hash +
        # source_snapshot_hash + engine_version.
        def key_scope(packet)
          plan.forecast_projection_caches.where(
            plan_version: packet.plan[:version],
            scenario_stack_hash: packet.scenario_stack_hash,
            source_snapshot_hash: packet.source_snapshot_hash,
            engine_version: packet.engine_version
          )
        end

        # Stable digest of the result envelope, stored on the cache so identical
        # recomputes coalesce and changed regions are detectable.
        def result_hash(result)
          Forecasts::Projection.stable_hash(result.to_h)
        end

        def metric_key_for(trace)
          METRIC_KEY_FOR_CATEGORY.fetch(trace.category, trace.category)
        end

        # The assumption ids whose traces contribute to this period, sorted for a
        # deterministic stored payload.
        def active_assumption_ids_for(period_traces)
          period_traces.map(&:assumption_id).compact.uniq.sort_by(&:to_s)
        end

        # Privacy-safe issue code list scoped to this period (codes only, no
        # financial detail), built from the engine's structured issues.
        def issue_codes_for(result, period)
          result.issues
            .select { |issue| issue.period.to_s == period[:key].to_s }
            .map(&:code)
            .uniq
        end

        # Privacy-safe issue summary for the cache row: counts and codes only.
        def issue_summary(result)
          {
            "status" => result.status,
            "issue_count" => result.issues.length,
            "codes" => result.issues.map(&:code).tally
          }
        end

        def source_record_refs_payload(trace)
          { "refs" => trace.source_record_refs }
        end

        def started_at
          @started_at ||= Time.current
        end

        # Estimates the monthly period count the engine will simulate from the
        # plan horizon (no DB read, no clock): the inclusive month span between
        # the horizon endpoints. Used only for the sync-vs-background decision.
        def projected_period_count
          start_on = plan.horizon_start_on
          end_on = plan.horizon_end_on
          return Forecasts::Projection::PeriodSimulator::DEFAULT_PERIOD_COUNT if start_on.nil? || end_on.nil?

          months = ((end_on.year - start_on.year) * 12) + (end_on.month - start_on.month)
          [ months, 1 ].max
        end
    end
  end
end
