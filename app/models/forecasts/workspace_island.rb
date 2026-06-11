# frozen_string_literal: true

module Forecasts
  # Builds the workspace's single JSON data island (spec §4 contract, parts
  # a+b+c). Everything the chart, metric column, lens tabs, scrubber,
  # inspector, AND the JS preview engine need ships here ONCE, so scrubbing,
  # lens switching, and per-keystroke previews are zero-network.
  #
  # Two sources, one byte-identical island (plan Amendment A):
  # - `.from_cache(plan:, cache:)` — GET path, reads persisted period rows;
  #   the packet-lite builds from the cache's own source snapshot.
  # - `.from_result(plan:, result:, snapshot:)` — save path, reads the
  #   in-memory engine Result (compute-synchronous, persist-async: the Turbo
  #   Stream response renders from the Result while
  #   ForecastProjectionPersistJob writes the cache off-request). The caller
  #   threads the SAME snapshot the result was computed from, so both paths
  #   build the packet-lite from identical inputs.
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
  #   labels: i18n strings the chart/inspector render client-side — the
  #           island is the only payload the chart re-reads after a stream
  #           patch, so hardcoded client strings would dodge localization
  #   packet: "packet lite" (part c) — the JS preview engine's input: engine
  #           horizon/currency/opening balances plus per-assumption resolved
  #           engine params and a `pv` preview gate; nil when no snapshot is
  #           available (the island keeps rendering, preview simply stays off)
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
      raise ArgumentError, "cache is required — callers must skip the island when no cache exists" if cache.nil?

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

      new(plan: plan, period_tuples: tuples, snapshot: cache.forecast_source_snapshot)
    end

    # Save path: monthly period tuples from the in-memory engine Result.
    # Result periods carry symbol-keyed metrics with the SAME decimal strings
    # the cache rows store (Metrics#to_h is the single producer for both), and
    # active assumption ids derive from the trace rows grouped by period —
    # compact/unique/sorted exactly as RecomputeCoordinator persists them.
    def self.from_result(plan:, result:, snapshot:)
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

      new(plan: plan, period_tuples: tuples, snapshot: snapshot)
    end

    def initialize(plan:, period_tuples:, snapshot:)
      @plan = plan
      @period_tuples = period_tuples
      @snapshot = snapshot
    end
    private_class_method :new

    def to_h
      entries = assumption_entries
      index_by_id = entries.each_with_index.to_h { |entry, i| [ entry[:id], i ] }

      {
        plan: plan_section,
        periods: period_rows(index_by_id),
        assumptions: entries,
        labels: labels_section,
        packet: packet_section
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

      # --- Labels (island-carried i18n) -------------------------------------

      # The chart and inspector render after every island (re)parse, including
      # Turbo Stream patches that bypass the ERB layer — so their strings must
      # ride the island, not the templates.
      def labels_section
        {
          metrics: I18n.t("forecasts.workspace.metrics"),
          inspector: I18n.t("forecasts.workspace.inspector")
        }
      end

      # --- Packet lite (spec §4 part c) --------------------------------------

      # The JS preview engine's input. nil simply turns preview off — the
      # island must keep rendering parts a+b even when the packet cannot be
      # built (no snapshot yet, or a build failure), so this NEVER raises.
      def packet_section
        return nil if @snapshot.nil?

        packet = Forecasts::Projection::PacketBuilder
          .new(plan: @plan, source_snapshot: @snapshot, anchor_on: packet_anchor)
          .build
        milestones_by_key = packet.milestones.index_by { |m| m[:key].to_s }
        opening = packet.source_snapshot[:opening_balances] || {}

        {
          horizon: {
            starts_on: packet.plan.dig(:horizon, :starts_on),
            ends_on: packet.plan.dig(:horizon, :ends_on)
          },
          currency: @plan.reporting_currency,
          opening: {
            lc: opening[:liquid_cash],
            db: opening[:debt_balance],
            pv: opening[:portfolio_value]
          },
          assumptions: packet.assumptions.map { |s| packet_assumption(s, milestones_by_key) }
        }
      rescue StandardError => e
        Rails.logger.error("forecast island packet build failed plan=#{@plan.id} #{e.class}")
        nil
      end

      # The island's periods already encode the projection's effective horizon
      # (spec §10 re-anchoring: the original compute ran with anchor_on=today
      # and PacketBuilder clamped the horizon start to
      # min(max(BOM(anchor), horizon_start_on), BOM(horizon_end_on))). Anchoring
      # the rebuilt packet at the FIRST period tuple's start date reproduces
      # that exact horizon: the first period start IS the original effective
      # BOM, and effective_horizon_start_on is idempotent over it. Byte-identity
      # across the GET and save paths depends on this — never anchor at
      # Date.current here.
      def packet_anchor
        first = @period_tuples.first
        first ? Date.parse(first[:starts_on].to_s) : @plan.horizon_start_on
      end

      # One packet-lite assumption: the engine-shaped params with milestone
      # anchors pre-resolved to plain dates (the JS engine does no milestone
      # lookups — packet-lite anchors are ALWAYS {type:"date", on:}), plus the
      # `pv` flag gating the preview path: anchors must be resolvable, the
      # kind must ship a JS mirror (Registry.preview_for), and the params must
      # be in the plan currency (the JS engine does no FX).
      def packet_assumption(section, milestones_by_key)
        params = section[:params].dup # packet params are deep-frozen; copy before rewriting anchors
        resolvable = true

        %i[start_anchor end_anchor].each do |key|
          anchor = params[key]
          next unless anchor.is_a?(Hash) && anchor[:type].to_s == "milestone"

          resolved_on = milestones_by_key.dig(anchor[:milestone_key].to_s, :resolved_on)
          if resolved_on
            params[key] = { type: "date", on: resolved_on }
          else
            resolvable = false
          end
        end

        pv = resolvable &&
          Forecasts::Assumptions::Registry.preview_for(section[:kind]) &&
          (params[:currency].nil? || params[:currency].to_s == @plan.reporting_currency)

        { id: section[:id], kind: section[:kind], pv: pv, params: params }
      end
  end
end
