# frozen_string_literal: true

require "bigdecimal"
require "digest"

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
    #   3. Persist a Forecasts::ProjectionCache + indexed ProjectionPeriod rows in
    #      ONE transaction, keyed by forecast_plan_id + plan_version +
    #      scenario_stack_hash + source_snapshot_hash + engine_version. Traces are
    #      still persisted per period (spec 3.2.2) — embedded on each period row
    #      as a compact ordered jsonb array (see ProjectionPeriod::TRACE_KEYS),
    #      not as relational rows.
    #
    # The coordinator is NOT the engine: it owns persistence, key/version
    # management, and cache invalidation. It does NOT format UI strings or
    # broadcast — those live in read models / controllers.
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
    # unchanged. Publishing a new current cache replaces (deletes, atomically in
    # the same transaction) any prior cache for the same plan + scenario stack,
    # so there is at most one live cache per scenario stack.
    #
    # Family scoping: the family is derived from the plan record, never from
    # caller params (the PacketBuilder enforces snapshot/plan/family ownership).
    class RecomputeCoordinator
      InvalidRecomputeInputError = Class.new(ArgumentError)

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

      def initialize(plan:, source_snapshot:, anchor_on: nil)
        raise InvalidRecomputeInputError, "plan is required" if plan.nil?
        raise InvalidRecomputeInputError, "source_snapshot is required" if source_snapshot.nil?

        @plan = plan
        @source_snapshot = source_snapshot
        @anchor_on = anchor_on
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

      private
        def build_packet
          Forecasts::Projection::PacketBuilder.new(
            plan: plan,
            source_snapshot: source_snapshot,
            anchor_on: @anchor_on
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

        # Persists the cache and the period rows (which embed the traces) in one
        # transaction, replacing any prior cache for the same plan + scenario
        # stack. The stale guard is re-checked INSIDE the transaction so a
        # version bump racing with this write cannot publish over a newer plan
        # version.
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

            replace_prior_caches!(packet)
            cache = write_cache!(packet, result)
            write_periods!(cache, packet, result)
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

        # Supersede + prune in ONE statement (one PG round trip on the
        # synchronous save path instead of two). At most one current cache per
        # plan + scenario stack: matching by scenario_stack_key (not the exact
        # version key) ensures a newer version's publish replaces the prior
        # version's live cache for the same stack. The replaced rows are deleted
        # outright rather than first being marked superseded — the delete and
        # the publish happen inside this same transaction, so no reader can ever
        # observe an intermediate state, and cache hygiene (spec §8) wants the
        # rows gone anyway: auto-save bumps the plan version on every settle, so
        # without this hard delete the table grows by ~361 period rows per
        # keystroke-settle. Runs BEFORE the new cache row is written so the
        # partial unique current-key index cannot collide with a replaced row.
        # Pinned snapshot rows (phase 8 adds pinned_at) will be excluded here
        # when pinning exists.
        def replace_prior_caches!(packet)
          plan.forecast_projection_caches
            .where(scenario_stack_key: packet.scenario_stack[:key])
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
        #
        # Each period row embeds its explanation traces as a compact ordered
        # jsonb array (see ProjectionPeriod::TRACE_KEYS) built in the same pass:
        # traces are still persisted per period (spec §3.2.2) — only the storage
        # shape changed. Relational trace rows cost ~9k inserts per 30-year save
        # (~43% of the synchronous save budget in PG I/O alone); the embedded
        # blob rides along on the 361 period inserts.
        def write_periods!(cache, packet, result)
          traces_by_period = result_traces(result).group_by(&:period_key)
          now = Time.current
          entry_jsons = {}
          blob_jsons = {}
          # Same-id-set periods share one frozen ids array (and one JSON string
          # via the column's pass-through codec input being identical).
          id_sets = {}

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
              traces: traces_json(period_traces, entry_jsons, blob_jsons),
              issue_codes: issue_codes_for(result, period),
              active_assumption_ids: active_assumption_ids_for(period_traces, id_sets),
              plan_version: packet.plan[:version],
              engine_version: packet.engine_version,
              created_at: now,
              updated_at: now
            }
          end

          Forecasts::ProjectionPeriod.insert_all!(rows) if rows.any?
        end

        # Builds one period's embedded traces as a pre-generated JSON array
        # string (ProjectionPeriod::TracesJsonbType passes it through), in the
        # engine's ledger order (array position IS display order), skipping
        # zero-amount traces (spec §3.2.2: traces exist to explain flows; a zero
        # flow explains nothing and at 30y scale zero entries dominate the
        # payload).
        #
        # `entry_jsons` memoizes one entry's JSON (nil for a filtered zero
        # amount) per [assumption_id, amount] across the whole save. That key is
        # injective for the stored entry: every other stored field is a function
        # of the assumption alone — the TraceBuilder derives source_type,
        # category (hence metric_key and direction), currency, explanation_key,
        # and the shared refs array from per-assumption data; only the amount
        # varies across one assumption's occurrences. A 30-year save therefore
        # encodes ~25 entry strings instead of ~9k.
        def traces_json(period_traces, entry_jsons, blob_jsons)
          parts = period_traces.filter_map do |trace|
            entry_jsons.fetch([ trace.assumption_id, trace.amount ]) do |key|
              entry_jsons[key] = trace_entry_json(trace)
            end
          end
          # Periods with identical entries (flat assumptions are identical every
          # month) share ONE blob string instead of allocating ~5KB × 361.
          blob_jsons[parts] ||= "[#{parts.join(',')}]"
        end

        # Encodes one embedded trace entry (compact keys documented on
        # ProjectionPeriod::TRACE_KEYS), or nil when the amount is zero.
        def trace_entry_json(trace)
          return nil if BigDecimal(trace.amount.to_s).zero?

          JSON.generate(
            "a" => trace.assumption_id,
            "mk" => metric_key_for(trace),
            "d" => trace.direction || DIRECTION_FOR_CATEGORY[trace.category],
            "am" => trace.amount.to_s,
            "c" => trace.currency,
            "k" => trace.category,
            "e" => trace.explanation_key,
            "r" => trace.source_record_refs
          )
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
        #
        # Three fully-derived sections are deliberately excluded from the hashed
        # payload — each is a pure function of the packet and engine version,
        # both already inside the cache key, so two results that agree on
        # everything else cannot differ in them, and serializing them dominated
        # the synchronous save budget:
        # - traces (~9k hashes; canonicalizing them doubled the save budget),
        # - series (a byte-for-byte duplicate of the periods' :metrics),
        # - per-period :trace_ids (~9k long derived id strings; per-period trace
        #   coverage is still pinned by the hashed periods + summary trace_count).
        #
        # Digested as a single JSON.generate pass instead of the order-canonical
        # Forecasts::Projection.stable_hash walk: stable_hash exists to make
        # hashes independent of hash-key insertion order, but every node of this
        # payload is built with a FIXED key order by exactly two deterministic
        # producers — hashable_result_payload below (literal key order) and the
        # pure engine's envelope (periods/issues/goals/summary, constructed in
        # one deterministic pass and deep-frozen). The same result therefore
        # always serializes to the same bytes, and two structurally different
        # results cannot share bytes (JSON encodes structure faithfully; the
        # key-order/symbol-vs-string collisions stable_hash defends against
        # cannot arise from a single fixed-order producer). Walking ~3k metric
        # strings through canonicalize cost a measurable slice of the save
        # budget; the C JSON encoder does not.
        #
        # Memoized: the publish path needs the digest twice (coalescing check +
        # cache row).
        def result_hash(result)
          @result_hashes ||= {}
          @result_hashes[result.object_id] ||=
            Digest::SHA256.hexdigest(JSON.generate(hashable_result_payload(result)))
        end

        # The slimmed envelope result_hash digests (see exclusions there). Field
        # order is FIXED — the JSON digest above depends on it — and mirrors
        # Result#to_h for readability.
        def hashable_result_payload(result)
          {
            schema_version: result.schema_version,
            engine_version: result.engine_version,
            input_packet_hash: result.input_packet_hash,
            source_snapshot_hash: result.source_snapshot_hash,
            scenario_stack_hash: result.scenario_stack_hash,
            plan_version: result.plan_version,
            status: result.status,
            periods: result.periods.map { |period| period.except(:trace_ids) },
            issues: result.issues.map(&:to_h),
            goals: result.goals,
            summary: result.summary
          }
        end

        # Persistence consumes the engine's compact trace rows when present
        # (their field readers are identical to Trace's) and falls back to
        # Trace value objects for results built from raw hashes.
        def result_traces(result)
          result.trace_rows || result.traces
        end

        def metric_key_for(trace)
          METRIC_KEY_FOR_CATEGORY.fetch(trace.category, trace.category)
        end

        # The assumption ids whose traces contribute to this period, sorted for a
        # deterministic stored payload and pre-encoded as JSON (the column's
        # pass-through codec stores the string as-is). Memoized by id set — most
        # periods of one plan share the same active set, so a 30-year save sorts
        # and encodes once instead of 361 times.
        def active_assumption_ids_for(period_traces, id_sets)
          ids = period_traces.map(&:assumption_id)
          id_sets[ids] ||= JSON.generate(ids.compact.uniq.sort_by(&:to_s))
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

        def started_at
          @started_at ||= Time.current
        end
    end
  end
end
