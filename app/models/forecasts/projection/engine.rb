# frozen_string_literal: true

module Forecasts
  module Projection
    # The single public entrypoint for the pure Forecast V2 projection engine.
    #
    #   Forecasts::Projection::Engine.call(packet) -> Forecasts::Projection::Result
    #
    # The engine wires the documented pipeline:
    #
    #   1. Validate packet
    #   2. Assumption expansion (typed expanders -> flows)
    #   3. Flow ledger (normalize + deterministically order flows)
    #   4. Period simulation (36-month metric rows + plan issues)
    #   5. Goal evaluation (stub for the proof slice)
    #   6. Trace builder (one explanation trace per flow)
    #   7. Result envelope (versioned, hashed, status-tagged)
    #
    # It is PURE: it accepts only a validated plan packet value object (or a raw
    # packet hash it wraps into one). It does NOT accept ActiveRecord models,
    # relations, controller params, request context, or family/user objects. It
    # does NOT persist records, enqueue jobs, broadcast updates, format UI
    # strings, or call providers. It is deterministic for the same packet: the
    # same packet + engine version yields byte-identical output. The run/as-of
    # date is threaded through the packet horizon and source snapshot; the engine
    # never reads `Date.current`.
    #
    # See spec "Engine Contract Envelope", "Pipeline", "Trace Builder".
    class Engine
      InvalidInputError = Class.new(ArgumentError)

      # Expander dispatch by assumption kind. The catalog grows as later slices
      # land their expanders; this proof slice covers salary + living_expense.
      EXPANDERS = {
        "salary" => Forecasts::Projection::Expanders::Salary,
        "living_expense" => Forecasts::Projection::Expanders::LivingExpense
      }.freeze

      # Assumption statuses that contribute flows. Disabled/archived assumptions
      # produce no flows but remain explainable in the editor (spec invariant:
      # "Disabled assumptions produce no flows and still remain explainable").
      ACTIVE_STATUSES = %w[active draft].freeze

      def self.call(packet)
        new(packet).call
      end

      def initialize(packet)
        @packet = coerce_packet(packet)
      end

      def call
        ledger = build_ledger
        outcome = simulate(ledger)
        traces = build_traces(ledger, outcome.periods)
        periods = attach_trace_ids(outcome.periods, traces)
        goals = evaluate_goals(outcome.periods)

        Forecasts::Projection::Result.new(
          schema_version: packet.schema_version,
          engine_version: packet.engine_version,
          input_packet_hash: packet.input_packet_hash,
          source_snapshot_hash: packet.source_snapshot_hash,
          scenario_stack_hash: packet.scenario_stack_hash,
          plan_version: plan_version,
          status: outcome.status,
          periods: periods,
          series: build_series(periods),
          traces: traces,
          issues: outcome.issues,
          goals: goals,
          summary: build_summary(outcome, traces)
        )
      end

      private
        attr_reader :packet

        # --- Input coercion / purity guard ---------------------------------

        # The engine accepts only a Packet value object or a raw packet hash it
        # wraps. Anything ActiveRecord-shaped (a record or a relation), params,
        # or nil is rejected with a typed error BEFORE any simulation runs. This
        # is the boundary that keeps the engine pure.
        def coerce_packet(input)
          return input if input.is_a?(Forecasts::Projection::Packet)

          reject_non_packet!(input)
          Forecasts::Projection::Packet.new(input)
        end

        def reject_non_packet!(input)
          if input.nil?
            raise InvalidInputError, "Engine.call requires a packet; got nil"
          end

          if active_record_shaped?(input)
            raise InvalidInputError,
              "Engine.call must not receive ActiveRecord objects, relations, params, " \
              "or family/user objects (got #{input.class}); pass a Forecasts::Projection::Packet"
          end

          return if input.is_a?(Hash)

          raise InvalidInputError,
            "Engine.call requires a Forecasts::Projection::Packet or packet hash (got #{input.class})"
        end

        # Detects ActiveRecord models, relations, and params-like objects without
        # referencing those constants directly (the engine must not depend on
        # ActiveRecord). Plain hashes are explicitly allowed through.
        def active_record_shaped?(input)
          return false if input.is_a?(Hash)

          defined?(ActiveRecord::Base) && input.is_a?(ActiveRecord::Base) ||
            defined?(ActiveRecord::Relation) && input.is_a?(ActiveRecord::Relation) ||
            input.class.respond_to?(:reflect_on_all_associations) ||
            input.respond_to?(:to_sql) ||
            input.respond_to?(:permit)
        end

        # --- Pipeline -------------------------------------------------------

        # Assumption expansion + flow ledger. Each enabled assumption is routed
        # to its typed expander with the normalized context (reporting currency,
        # horizon, plan version, assumption id, scenario layer, resolved
        # milestone dates). Unknown/disabled kinds emit no flows.
        def build_ledger
          flows = packet.assumptions.flat_map { |assumption| expand(assumption) }
          Forecasts::Projection::FlowLedger.new(flows)
        end

        def expand(assumption)
          assumption = Forecasts::Projection.deep_symbolize(assumption)
          return [] unless enabled?(assumption)

          expander_class = EXPANDERS[assumption[:kind].to_s]
          return [] if expander_class.nil?

          expander_class.new(
            params: assumption[:params] || {},
            context: expansion_context(assumption)
          ).expand
        end

        def enabled?(assumption)
          status = (assumption[:status] || "active").to_s
          ACTIVE_STATUSES.include?(status)
        end

        def expansion_context(assumption)
          {
            reporting_currency: reporting_currency,
            horizon: horizon,
            plan_version: plan_version,
            assumption_id: assumption[:id],
            scenario_layer_id: assumption[:scenario_layer_id],
            milestone_dates: milestone_dates
          }
        end

        def simulate(ledger)
          Forecasts::Projection::PeriodSimulator.new(
            ledger: ledger,
            horizon: horizon,
            source_snapshot: packet.source_snapshot,
            reporting_currency: reporting_currency,
            issue_policy: packet.issue_policy
          ).simulate
        end

        # Traces are built only for flows that fall inside a simulated period, so
        # every trace references an existing period row and each period's
        # `trace_ids` are complete. Flows the simulator does not reach (e.g. a
        # flow dated on the horizon end boundary, which belongs to the month
        # after the last simulated period) produce no orphaned trace.
        def build_traces(ledger, periods)
          period_keys = periods.map { |period| period[:key] }.to_set
          simulated_flows = ledger.flows.select { |flow| period_keys.include?(flow.period_key) }

          Forecasts::Projection::TraceBuilder.new(
            ledger: Forecasts::Projection::FlowLedger.new(simulated_flows),
            plan_version: plan_version
          ).build
        end

        def evaluate_goals(periods)
          Forecasts::Projection::GoalEvaluator.new(
            goals: goal_assumptions,
            periods: periods,
            reporting_currency: reporting_currency
          ).evaluate
        end

        # --- Result assembly ------------------------------------------------

        # Replaces each period row's `trace_ids` with the ids of the traces whose
        # period matches. The simulator leaves these empty because traces are
        # built after simulation; the engine is the single place that joins them.
        def attach_trace_ids(periods, traces)
          ids_by_period = traces.group_by(&:period_key).transform_values do |group|
            group.map(&:id)
          end

          periods.map do |period|
            period.merge(trace_ids: ids_by_period.fetch(period[:key], []))
          end
        end

        # Chart-ready compact metric series, one entry per period: key + the
        # period's metric values. Read models slice this for the chart without
        # reparsing the full result.
        def build_series(periods)
          periods.map do |period|
            { key: period[:key], metrics: period[:metrics] }
          end
        end

        def build_summary(outcome, traces)
          {
            status: outcome.status,
            period_count: outcome.periods.length,
            trace_count: traces.length,
            issue_count: outcome.issues.length,
            goal_count: goal_assumptions.length
          }
        end

        # --- Packet readers -------------------------------------------------

        def plan
          @plan ||= packet.plan
        end

        # `plan_version` is threaded through the packet so trace keys and the
        # result envelope stay stable for a given plan revision. Defaults to 0
        # when absent so the engine still produces a deterministic result.
        def plan_version
          plan[:version] || 0
        end

        def reporting_currency
          plan[:reporting_currency]
        end

        def horizon
          plan[:horizon] || {}
        end

        # Resolved milestone dates keyed by milestone key, threaded to expanders.
        # Built from the packet milestones; expanders look these up rather than
        # resolving references themselves.
        def milestone_dates
          @milestone_dates ||= packet.milestones.each_with_object({}) do |milestone, memo|
            milestone = Forecasts::Projection.deep_symbolize(milestone)
            key = (milestone[:key] || milestone[:milestone_key]).to_s
            next if key.empty?

            memo[key] = milestone[:resolved_on] || milestone[:on] || milestone[:date]
          end
        end

        def goal_assumptions
          @goal_assumptions ||= packet.assumptions.select do |assumption|
            Forecasts::Projection.deep_symbolize(assumption)[:kind].to_s == "goal"
          end
        end
    end
  end
end
