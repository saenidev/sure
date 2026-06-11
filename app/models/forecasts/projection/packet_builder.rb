# frozen_string_literal: true

require "bigdecimal"

module Forecasts
  module Projection
    # Forecast V2 plan packet builder. Combines an editable `Forecasts::Plan`, its
    # enabled baseline assumptions (salary + living_expense for the proof slice),
    # the baseline scenario stack, resolved milestones, and a persisted
    # `Forecasts::SourceSnapshot` into a single `Forecasts::Projection::Packet`
    # value object with version metadata.
    #
    # The packet is the engine input contract (spec "Plan Packet"). This builder
    # is the seam between ActiveRecord plan authoring and the pure engine: it is
    # the LAST place that touches models. It reads the plan and its associations,
    # but it neither persists nor renders (boundary table: "Plan packet builder |
    # Combining plan, scenario stack, source snapshot, and version metadata into
    # engine input | Persistence or UI rendering").
    #
    # Determinism: the same plan version + source snapshot hash yields the same
    # packet hash. Nothing here reads `Date.current` / `Time.current`; the run/
    # as-of date is threaded through the source snapshot (already serialized) and
    # the plan horizon. Money is serialized to decimal strings, never floats.
    #
    # Family scoping (spec "Security"): the family is read off the plan record
    # (`plan.family_id`). The builder never accepts or trusts a family_id from
    # params, Inertia props, JSON payloads, or callers.
    class PacketBuilder
      InvalidBuilderInputError = Class.new(ArgumentError)

      # Bumped whenever the packet SHAPE changes (spec "Versioning rules").
      SCHEMA_VERSION = 1
      # Bumped whenever the engine's SEMANTICS change. The engine echoes this back
      # in its result envelope; the recompute coordinator keys caches on it.
      # v2.2: trace/flow ids moved from SHA256 digests to delimited composite
      # keys (same stability + uniqueness contract); metric math unchanged.
      ENGINE_VERSION = "forecast_v2.2"

      # Baseline stack: no scenario layers applied. Later slices add real stacks.
      BASELINE_SCENARIO_KEY = "baseline"

      # Assumption statuses that participate in the baseline projection. Mirrors
      # the engine's ACTIVE_STATUSES; disabled/archived assumptions are excluded
      # here so they never reach the engine as flows (they stay editable/
      # explainable through the read models, not the packet).
      ENABLED_STATUSES = %w[active draft].freeze

      # Default occurrence cadence when an assumption row has not yet recorded one
      # in its typed params. Keeps source-derived defaults (which only store
      # amount/currency) expandable without fabricating other semantics.
      DEFAULT_FREQUENCY = "monthly"

      attr_reader :plan, :source_snapshot, :family

      def initialize(plan:, source_snapshot:, anchor_on: nil)
        raise InvalidBuilderInputError, "plan is required" if plan.nil?
        raise InvalidBuilderInputError, "source_snapshot is required" if source_snapshot.nil?

        @plan = plan
        @source_snapshot = source_snapshot
        @anchor_on = anchor_on&.to_date
        # Family scope is derived from the plan, never from caller-supplied params.
        @family = plan.family

        validate_ownership!
      end

      # Returns a frozen, validated Forecasts::Projection::Packet ready for the
      # pure engine. Builds nothing else and writes nothing.
      def build
        Forecasts::Projection::Packet.new(
          schema_version: SCHEMA_VERSION,
          engine_version: ENGINE_VERSION,
          plan: plan_section,
          scenario_stack: scenario_stack_section,
          milestones: milestone_sections,
          assumptions: assumption_sections,
          scenario_operations: [],
          source_snapshot: source_snapshot_payload,
          issue_policy: issue_policy_section
        )
      end

      private
        # The source snapshot must belong to the same plan/family. This is a seam
        # guard: a mismatched snapshot would silently project one plan against
        # another family's data.
        def validate_ownership!
          return if source_snapshot.forecast_plan_id == plan.id && source_snapshot.family_id == plan.family_id

          raise InvalidBuilderInputError,
            "source_snapshot does not belong to the plan/family it is being packed with"
        end

        # --- Plan section ---------------------------------------------------

        def plan_section
          {
            id: plan.id,
            family_id: plan.family_id,
            version: plan_version,
            reporting_currency: plan.reporting_currency,
            horizon: {
              starts_on: date_string(effective_horizon_start_on),
              ends_on: date_string(plan.horizon_end_on),
              near_term_daily_days: near_term_daily_days
            }
          }
        end

        # Plan revision counter, threaded so trace ids and the result envelope
        # stay stable for a given plan version. Read off the persisted plan, never
        # the clock.
        def plan_version
          plan.current_plan_version
        end

        def near_term_daily_days
          settings = plan.settings || {}
          settings["near_term_daily_days"] || settings[:near_term_daily_days] || 90
        end

        # Re-anchoring (spec §10): a recompute simulates from the anchor month
        # forward — past months are history, rendered from actuals, never
        # re-simulated. The anchor is threaded by the caller (controller passes
        # the current date); this builder never reads the clock. Clamped so a
        # plan whose horizon has fully elapsed still yields >= 1 period.
        def effective_horizon_start_on
          return plan.horizon_start_on if @anchor_on.nil?

          anchored = [ @anchor_on.beginning_of_month, plan.horizon_start_on ].max
          [ anchored, plan.horizon_end_on.beginning_of_month ].min
        end

        # --- Scenario stack -------------------------------------------------

        # Baseline stack only for the proof slice: no layers, no operations. The
        # shape matches the engine contract so later slices can populate it.
        def scenario_stack_section
          { key: BASELINE_SCENARIO_KEY, layer_ids: [] }
        end

        # --- Milestones -----------------------------------------------------

        # Resolved milestone anchors keyed for the engine. Each milestone's date
        # is the deterministic resolution expanders look up via `resolved_on`.
        # Sorted by id so the packet hash is order-independent of load order.
        def milestone_sections
          plan.forecast_milestones
            .sort_by { |milestone| milestone.id.to_s }
            .map do |milestone|
              {
                id: milestone.id,
                key: milestone.id,
                kind: milestone.kind,
                resolved_on: date_string(milestone.date)
              }
            end
        end

        # --- Assumptions ----------------------------------------------------

        # Enabled baseline assumptions mapped into the engine assumption shape.
        # Each AR row's typed columns (amount/currency/starts_on/ends_on/milestone
        # refs) are merged into its stored `params` so the expander receives a
        # complete, deterministic params contract (spec "Assumption Params
        # Contracts"). Sorted by id for an order-independent packet hash.
        def assumption_sections
          enabled_assumptions
            .sort_by { |assumption| assumption.id.to_s }
            .map { |assumption| assumption_section(assumption) }
        end

        def enabled_assumptions
          plan.forecast_assumptions.select do |assumption|
            ENABLED_STATUSES.include?(assumption.status.to_s)
          end
        end

        def assumption_section(assumption)
          {
            id: assumption.id,
            kind: assumption.kind,
            status: assumption.status,
            scenario_layer_id: nil,
            params: assumption_params(assumption)
          }
        end

        # Merge order matters: stored typed params win for keys they define, then
        # the canonical columns fill in amount/currency and override timing with
        # the persisted anchors so the engine never relies on stale param copies.
        # Policy params are normalized last so the form's flat string shape becomes
        # the engine's typed-hash policy shape.
        def assumption_params(assumption)
          base = Forecasts::Projection.deep_symbolize(assumption.params || {})

          base
            .merge(column_params(assumption))
            .merge(anchor_params(assumption))
            .merge(policy_params(base))
        end

        # The typed form objects (B14) persist growth/inflation as a flat policy
        # STRING (`flat` / `fixed_rate`) plus a separate percentage rate, but the
        # pure engine expanders (B5) read a typed policy HASH
        # (`{ type: "none" | "annual_percentage", rate: <fraction> }`). This seam —
        # the last place that touches models — translates the persisted form shape
        # into the engine shape so the saved assumption recomputes deterministically
        # (spec "Plan packet builder ... into engine input"). A policy already stored
        # as a hash (legacy/test shape) is passed through untouched.
        def policy_params(base)
          normalized = {}
          normalized[:growth_policy] = engine_policy(base[:growth_policy], base[:growth_rate]) if base.key?(:growth_policy)
          normalized[:inflation_policy] = engine_policy(base[:inflation_policy], base[:inflation_rate]) if base.key?(:inflation_policy)
          normalized[:actualization_policy] = engine_type_policy(base[:actualization_policy]) if base.key?(:actualization_policy)
          normalized
        end

        # Maps a rate-less policy (e.g. living_expense's `actualization_policy`)
        # into the engine's typed policy hash. The form persists it as a flat
        # string (`none` / `replace` / `offset`) but the expander reads
        # `actualization_policy[:type]`, so a bare string crashes with a
        # TypeError. Translate it here at the seam, preserving the chosen type. A
        # value already stored as a hash (legacy/test shape) is passed through.
        def engine_type_policy(policy)
          return policy if policy.is_a?(Hash)
          return { type: "none" } if policy.blank?

          { type: policy.to_s }
        end

        # Maps one persisted policy value into the engine's typed policy hash. A
        # hash is already engine-shaped (passed through). A flat string maps:
        # `fixed_rate` (with a percentage rate) -> annual_percentage at the
        # fractional rate; anything else (e.g. `flat`) -> no growth.
        def engine_policy(policy, rate)
          return policy if policy.is_a?(Hash)

          if policy.to_s == "fixed_rate" && rate.present?
            { type: "annual_percentage", rate: fractional_rate(rate) }
          else
            { type: "none" }
          end
        end

        # The form stores rates as a percentage (e.g. "3.0" == 3%); the engine
        # compounds a fractional rate (e.g. 0.03). Convert at this seam.
        def fractional_rate(rate)
          (to_decimal(rate) / BigDecimal("100")).to_s("F")
        end

        def column_params(assumption)
          params = {}
          params[:amount] = decimal_string(assumption.amount) unless assumption.amount.nil?
          params[:currency] = assumption.currency.presence || plan.reporting_currency
          params[:frequency] = frequency_for(assumption)
          net_ratio = net_ratio_for(assumption)
          params[:net_ratio] = net_ratio unless net_ratio.nil?
          params
        end

        # A salary's optional gross→take-home fraction. The form persists it in
        # the typed params only for gross salaries; thread it through (normalized
        # to a decimal string) so the salary expander reduces the gross salary's
        # cash impact (spec salary row, "Assumption Params Contracts"). Absent for
        # net/derived salaries, leaving the engine's net == gross default intact.
        def net_ratio_for(assumption)
          stored = (assumption.params || {})
          raw = stored["net_ratio"] || stored[:net_ratio]
          return nil if raw.nil? || raw == ""

          decimal_string(raw)
        end

        def frequency_for(assumption)
          stored = (assumption.params || {})
          (stored["frequency"] || stored[:frequency]).presence || DEFAULT_FREQUENCY
        end

        # Convert the persisted start/end timing into deterministic anchors the
        # expander understands: an explicit milestone reference takes precedence
        # over a fixed date. Returns only the anchors that are set, so a missing
        # end anchor falls back to the plan horizon inside the expander.
        def anchor_params(assumption)
          anchors = {}
          start = anchor_for(assumption.starts_at_milestone_id, assumption.starts_on)
          finish = anchor_for(assumption.ends_at_milestone_id, assumption.ends_on)

          anchors[:start_anchor] = start unless start.nil?
          anchors[:end_anchor] = finish unless finish.nil?
          anchors
        end

        def anchor_for(milestone_id, on)
          return { type: "milestone", milestone_key: milestone_id } if milestone_id.present?
          return { type: "date", on: date_string(on) } if on.present?

          nil
        end

        # --- Source snapshot ------------------------------------------------

        # The already-normalized, serializable payload from the source snapshot
        # builder. Symbolized for the engine's canonical in-memory shape.
        def source_snapshot_payload
          Forecasts::Projection.deep_symbolize(source_snapshot.snapshot_payload || {})
        end

        # --- Issue policy ---------------------------------------------------

        # Default issue/fallback policy (spec "Plan Packet" minimum shape). Plan
        # source_policy can later override these; for the proof slice we use the
        # documented defaults so the engine behaves predictably.
        def issue_policy_section
          {
            missing_fx: "issue_limited",
            missing_price: "issue_limited",
            invalid_assumption: "block_recompute"
          }
        end

        # --- Serialization helpers ------------------------------------------

        def decimal_string(value)
          to_decimal(value).to_s("F")
        end

        def to_decimal(value)
          return BigDecimal("0") if value.nil? || value == ""
          return value if value.is_a?(BigDecimal)

          BigDecimal(value.to_s)
        end

        def date_string(value)
          return nil if value.nil?

          value.to_date.iso8601
        end
    end
  end
end
