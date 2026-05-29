module Forecast
  # Serializes a COMPLETED ForecastRunGroup into the structured JSON packet we
  # hand to Hermes (the external planning agent). The packet is a deterministic,
  # READ-ONLY projection of already-persisted, immutable run output — it never
  # recomputes the engine and never mutates the group. Reading only from the
  # baseline run's `input_snapshot` (which the Runner persisted) plus the run's
  # months / days / goal evaluations keeps the builder side-effect free and the
  # group immutable.
  #
  # The result is a Hash with an explicit `schema_version` and the spec's
  # sections:
  #   - run metadata (id, name, run_type, engine/input versions, generated_at)
  #   - family currency + horizon date range
  #   - current balances (cash / liquid / portfolio / debt / net worth at day 0)
  #   - projected monthly budget values (the 36-month income/spending series)
  #   - recurring summary (count + items from the input snapshot)
  #   - one-time events (forecast_events from the input snapshot)
  #   - debt + savings assumptions (debt rows + goals)
  #   - portfolio + market-close summary
  #   - scenario definitions (the stacks the group projected)
  #   - deterministic risk_flags (collapsed from the group/run output)
  #   - questions for Hermes (deterministic prompts derived from the facts)
  #
  # An EMPTY family (no scenarios / events / recurring / debt / goals) still
  # produces a valid packet: every section is present with empty arrays / zero
  # values, never nil and never a crash.
  class PacketBuilder
    SCHEMA_VERSION = "forecast-hermes-packet-v1".freeze

    class IncompleteRunGroup < StandardError; end

    def initialize(run_group)
      @run_group = run_group
    end

    # Returns the packet as a plain Hash (string keys) safe to persist as JSONB
    # onto ForecastReview#request_packet. Raises IncompleteRunGroup when the
    # group has not completed, so a caller never serializes a half-finished or
    # failed run as if it were a final fact set.
    def build
      unless run_group.completed?
        raise IncompleteRunGroup, "forecast run group must be completed before building a Hermes packet"
      end

      {
        "schema_version" => SCHEMA_VERSION,
        "run" => run_metadata,
        "currency" => run_group.currency,
        "horizon" => horizon,
        "current_balances" => current_balances,
        "monthly_budget" => monthly_budget_values,
        "recurring_summary" => recurring_summary,
        "one_time_events" => one_time_events,
        "debt_assumptions" => debt_assumptions,
        "savings_assumptions" => savings_assumptions,
        "portfolio_summary" => portfolio_summary,
        "market_close_summary" => market_close_summary,
        "scenarios" => scenario_definitions,
        "risk_flags" => risk_flags,
        "questions" => questions
      }
    end

    private
      attr_reader :run_group

      # The baseline run (empty scenario stack) is the headline projection we
      # serialize facts from. Falls back to the first completed run, then any
      # run, so a partial-failure comparison group still yields a packet from a
      # stack that completed rather than crashing. The runs (and their months)
      # are eager-loaded by the caller scope, so these reads add no queries.
      def baseline_run
        return @baseline_run if defined?(@baseline_run)

        runs = run_group.forecast_runs.to_a
        @baseline_run =
          runs.find { |run| run.scenario_stack_key == "baseline" && run.status == "completed" } ||
          runs.find { |run| run.status == "completed" } ||
          runs.first
      end

      # The baseline run's persisted input snapshot (the Runner wrote this from
      # Forecast::InputBuilder). All planning facts (accounts, budgets, recurring,
      # events, debt, goals, portfolio) are read from here so the packet reflects
      # exactly what the engine ran on — never a fresh recompute.
      def input_snapshot
        @input_snapshot ||= (baseline_run&.input_snapshot || {})
      end

      def run_metadata
        {
          "id" => run_group.id,
          "name" => run_group.name,
          "run_type" => run_group.run_type,
          "engine_version" => run_group.engine_version,
          "input_schema_version" => run_group.input_schema_version,
          "generated_at" => (run_group.finished_at || run_group.created_at)&.iso8601,
          "scenario_stack_count" => run_group.forecast_runs.size
        }
      end

      def horizon
        {
          "start_on" => run_group.horizon_start_on&.iso8601,
          "end_on" => run_group.horizon_end_on&.iso8601,
          "daily_until_on" => run_group.daily_until_on&.iso8601
        }
      end

      # Current (day-0) balances from the earliest projected day of the baseline
      # run. When the run produced no days (e.g. a family with nothing to
      # project) every balance is zero rather than nil.
      def current_balances
        day = baseline_days.first

        {
          "as_of" => day&.date&.iso8601 || run_group.horizon_start_on&.iso8601,
          "cash_balance" => decimal(day&.cash_balance),
          "liquid_balance" => decimal(day&.liquid_balance),
          "portfolio_value" => decimal(day&.portfolio_value),
          "debt_balance" => decimal(day&.debt_balance),
          "net_worth" => decimal(day&.net_worth)
        }
      end

      # The 36-month income/spending/net-cash-flow/net-worth series, one row per
      # projected month, ordered chronologically. Empty array when the run
      # produced no months.
      def monthly_budget_values
        baseline_months.map do |month|
          {
            "period_start_on" => month.period_start_on&.iso8601,
            "period_end_on" => month.period_end_on&.iso8601,
            "expected_income" => decimal(month.expected_income),
            "expected_spending" => decimal(month.expected_spending),
            "net_cash_flow" => decimal(month.net_cash_flow),
            "cash_balance" => decimal(month.cash_balance),
            "net_worth" => decimal(month.net_worth),
            "categories" => month_category_values(month)
          }
        end
      end

      # Per-category projected spending for a month, read from the eager-loaded
      # projection association (no N+1). Empty when the month has no categories.
      def month_category_values(month)
        month.forecast_category_projections.map do |projection|
          {
            "projection_key" => projection.projection_key,
            "category_id" => projection.category_id,
            "source" => projection.source,
            "projected_spending_expected" => decimal(projection.projected_spending_expected),
            "projected_spending_low" => decimal(projection.projected_spending_low),
            "projected_spending_high" => decimal(projection.projected_spending_high)
          }
        end
      end

      def recurring_summary
        items = Array(input_snapshot["recurring_items"])
        {
          "count" => input_snapshot.fetch("recurring_item_count", items.size),
          "items" => items
        }
      end

      def one_time_events
        Array(input_snapshot["forecast_events"])
      end

      def debt_assumptions
        {
          "count" => Array(input_snapshot["debt_rows"]).size,
          "rows" => Array(input_snapshot["debt_rows"]),
          "projections" => debt_projection_values
        }
      end

      # End-of-horizon debt projection rows from the last projected month, so
      # Hermes sees where each debt lands. Empty when there are no debt rows.
      def debt_projection_values
        month = baseline_months.last
        return [] if month.nil?

        month.forecast_debt_projections.map do |projection|
          {
            "projection_key" => projection.projection_key,
            "account_id" => projection.account_id,
            "opening_balance" => decimal(projection.opening_balance),
            "ending_balance" => decimal(projection.ending_balance),
            "projected_interest" => decimal(projection.projected_interest),
            "projected_payment" => decimal(projection.projected_payment),
            "cash_payment_gap" => decimal(projection.cash_payment_gap)
          }
        end
      end

      def savings_assumptions
        {
          "count" => input_snapshot.fetch("goal_count", Array(input_snapshot["goals"]).size),
          "goals" => Array(input_snapshot["goals"]),
          "evaluations" => goal_evaluation_values
        }
      end

      # Goal pass/warn/fail outcomes from the baseline run's evaluations
      # (eager-loaded by the caller scope). Empty when there are no goals.
      def goal_evaluation_values
        return [] if baseline_run.nil?

        baseline_run.forecast_goal_evaluations.map do |evaluation|
          {
            "goal_key" => evaluation.goal_key,
            "status" => evaluation.status,
            "metric_value" => decimal(evaluation.metric_value),
            "target_value" => decimal(evaluation.target_value),
            "evaluated_on" => evaluation.evaluated_on&.iso8601
          }
        end
      end

      def portfolio_summary
        portfolio = input_snapshot["portfolio"]
        return empty_portfolio_summary unless portfolio.is_a?(Hash)

        {
          "portfolio_value" => decimal(portfolio["portfolio_value"]),
          "cash_balance" => decimal(portfolio["cash_balance"]),
          "day_change" => decimal(portfolio["day_change"]),
          "market_data_quality" => portfolio["market_data_quality"],
          "holding_count" => Array(portfolio["holdings"]).size
        }
      end

      def empty_portfolio_summary
        {
          "portfolio_value" => "0.0",
          "cash_balance" => "0.0",
          "day_change" => "0.0",
          "market_data_quality" => nil,
          "holding_count" => 0
        }
      end

      # Why this run was triggered. For a market-close (or any automated) run the
      # trigger_metadata + the review's annotated trigger reason explain the
      # movement that surfaced it. Always present (empty hash when manual).
      def market_close_summary
        {
          "triggered_by" => run_group.run_type,
          "trigger_metadata" => run_group.trigger_metadata || {},
          "review_trigger" => review_trigger_metadata
        }
      end

      def review_trigger_metadata
        review = run_group.forecast_review
        return {} if review.nil?

        {
          "triggered" => review.triggered?,
          "reason" => review.response_packet["trigger_reason"],
          "flags" => Array(review.response_packet["trigger_flags"]),
          "metrics" => review.response_packet["trigger_metrics"] || {}
        }
      end

      # The scenario stacks the group projected, one entry per run, read from the
      # run's persisted scenario_stack_snapshot (never a live scenario lookup, so
      # the packet reflects exactly what ran). Baseline is included.
      def scenario_definitions
        run_group.forecast_runs.map do |run|
          {
            "scenario_stack_key" => run.scenario_stack_key,
            "feasibility_status" => run.feasibility_status,
            "status" => run.status,
            "snapshot" => run.scenario_stack_snapshot || {}
          }
        end
      end

      # Deterministic risk flags collapsed from the group's persisted risk_flags
      # (the Runner aggregated each run's flags here). Each flag is normalized to
      # its type token, deduped, so Hermes gets a stable, sorted list.
      def risk_flags
        Array(run_group.risk_flags)
          .map { |flag| flag.is_a?(Hash) ? flag["type"] : flag }
          .compact_blank
          .uniq
          .sort
      end

      # Deterministic questions for Hermes derived from the facts. These are not
      # AI output — they are stable prompts the facts warrant, so the packet is
      # self-describing even before any external round-trip. Always returns at
      # least one general question so the section is never empty.
      def questions
        list = []

        if any_negative_cash_month?
          list << "cash_runway_at_risk"
        end

        if Array(input_snapshot["debt_rows"]).any?
          list << "debt_paydown_optimization"
        end

        if Array(input_snapshot["goals"]).any?
          list << "goal_feasibility"
        end

        if risk_flags.any?
          list << "address_risk_flags"
        end

        list << "general_recommendations"
        list.uniq
      end

      def any_negative_cash_month?
        baseline_months.any? { |month| month.cash_balance.to_d.negative? }
      end

      # The baseline run's months, sorted chronologically in Ruby (the
      # association is eager-loaded, so sorting here avoids a second query).
      def baseline_months
        return @baseline_months if defined?(@baseline_months)
        return @baseline_months = [] if baseline_run.nil?

        @baseline_months = baseline_run.forecast_months.to_a.sort_by(&:period_start_on)
      end

      def baseline_days
        return @baseline_days if defined?(@baseline_days)
        return @baseline_days = [] if baseline_run.nil?

        @baseline_days = baseline_run.forecast_days.to_a.sort_by(&:date)
      end

      # Normalize a numeric/Money-ish value to a JSON-safe decimal string,
      # defaulting nil to "0.0" so balance/amount fields are never null.
      def decimal(value)
        return "0.0" if value.nil?

        BigDecimal(value.to_s).to_s("F")
      rescue ArgumentError, TypeError
        "0.0"
      end
  end
end
