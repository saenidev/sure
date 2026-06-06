# frozen_string_literal: true

require "bigdecimal"
require "bigdecimal/util"

module Forecasts
  module Projection
    # Applies the flow ledger over a fixed monthly horizon and produces per-period
    # metric rows. Pure value object: no ActiveRecord, no providers, no clock —
    # the run/as-of date is threaded through the horizon and source snapshot. All
    # arithmetic is decimal (BigDecimal); money never becomes a float. Foreign
    # currency flows are converted via the snapshot FX table (rate + source +
    # target + date); a missing rate emits a structured `missing_fx_rate`
    # PlanIssue (NOT an exception) and the converted value is excluded or held per
    # the issue policy.
    #
    # Flow ordering within each period follows the spec exactly: opening balances
    # and actuals -> income -> required debt interest -> required debt payments ->
    # spending -> transfers -> investment flows -> portfolio return -> goal
    # funding -> closing balances and issue impact. This proof slice expands only
    # income + spending, but the ordering scaffold is in place so later flow kinds
    # slot into their documented position.
    #
    # See spec "Period Simulation", "Flow Ordering", "Currency And Rounding", and
    # "Engine Invariants".
    class PeriodSimulator
      InvalidSimulationError = Class.new(ArgumentError)

      # Default count of monthly periods (3 years) when the horizon does not pin
      # an explicit end. The V2 MVP simulates a 36-month monthly horizon.
      DEFAULT_PERIOD_COUNT = 36

      # Sentinel for UNBOUNDED runway: positive liquid cash with zero burn never
      # runs out, so reporting "0 days" (insolvency) would be wrong. We surface a
      # large, documented constant instead of infinity so the value stays a plain
      # integer the UI/series can carry and compare. ~273 years of days — far
      # beyond any real horizon, unambiguously "effectively infinite" without
      # introducing Float::INFINITY (which would not be a clean integer/decimal).
      UNBOUNDED_RUNWAY_DAYS = 99_999

      # The order ledger effect categories are applied within a period. Lower
      # applies first. Mirrors spec "Flow Ordering" (steps 2-9); opening (1) and
      # closing (10) are handled by the surrounding balance carry, not by a flow.
      FLOW_ORDER = {
        "income" => 2,
        "debt_interest" => 3,
        "debt_service" => 4,
        "spending" => 5,
        "transfer" => 6,
        "portfolio_contribution" => 7,
        "portfolio_return" => 8,
        "goal_funding" => 9
      }.freeze

      # Result of a simulation run. Pure value object; `periods` are plain hashes
      # (compact, cache/UI-ready) and `issues` are PlanIssue value objects. The
      # engine (B7) folds these into the full Result envelope.
      class Outcome
        attr_reader :periods, :issues, :status

        def initialize(periods:, issues:)
          @periods = Forecasts::Projection.deep_freeze(periods)
          @issues = issues.freeze
          @status = derive_status(issues)
          freeze
        end

        private
          # `clean` with no issues; `issue_limited` once any non-info issue is
          # present (FX/price exclusions still render with held/excluded values).
          # `blocked` is reserved for plan-validation failures upstream of the
          # simulator, so it is never produced here.
          def derive_status(issues)
            return "clean" if issues.empty?
            return "clean" if issues.all? { |issue| issue.severity == "info" }

            "issue_limited"
          end
      end

      def initialize(ledger:, horizon:, source_snapshot:, reporting_currency:,
                     issue_policy: {}, period_count: DEFAULT_PERIOD_COUNT)
        @ledger = ledger
        @horizon = Forecasts::Projection.deep_symbolize(horizon || {})
        @snapshot = Forecasts::Projection.deep_symbolize(source_snapshot || {})
        @reporting_currency = reporting_currency
        @issue_policy = Forecasts::Projection.deep_symbolize(issue_policy || {})
        @period_count = period_count
        @issues = []
        @issue_keys = {}
      end

      def simulate
        balances = opening_balances
        periods = period_windows.map do |window|
          simulate_period(window, balances)
        end

        Outcome.new(periods: periods, issues: @issues)
      end

      private
        attr_reader :ledger, :snapshot, :reporting_currency, :issue_policy

        # --- Period windows -------------------------------------------------

        # The inclusive monthly windows the simulator walks, derived from the
        # horizon start. The count comes from the horizon span when present, else
        # the default 36 months.
        def period_windows
          start_on = horizon_start
          count = month_count
          Array.new(count) do |index|
            month_start = start_on >> index
            {
              index: index,
              key: format("%04d-%02d", month_start.year, month_start.month),
              starts_on: month_start.beginning_of_month,
              ends_on: month_start.end_of_month
            }
          end
        end

        # Number of monthly windows to simulate. The horizon is INCLUSIVE of the
        # month containing `horizon_end`: a flow dated on the horizon-end boundary
        # belongs to the period containing that date (spec "Period Boundaries"),
        # and Expanders::Base#occurrence_window clamps occurrences inclusively to
        # `horizon_end`. Counting the span months (end - start) would drop that
        # final month, so the boundary flow would be generated but never
        # simulated/traced. We add one so the horizon-end month is covered and the
        # two stay in agreement (simulated income trace count == expected
        # occurrences across the FULL horizon).
        def month_count
          start_on = horizon_start
          end_on = horizon_end
          return @period_count if end_on.nil?

          span = ((end_on.year - start_on.year) * 12) + (end_on.month - start_on.month)
          [ span + 1, 1 ].max
        end

        def horizon_start
          @horizon_start ||= parse_date(@horizon[:starts_on]) ||
            raise(InvalidSimulationError, "horizon.starts_on is required")
        end

        def horizon_end
          @horizon_end ||= parse_date(@horizon[:ends_on])
        end

        # --- Per-period simulation ------------------------------------------

        # Applies one period's flows over the running balances in spec flow order
        # and snapshots the closing metrics. `balances` is a mutable hash of
        # BigDecimal carried across periods (the running ledger). Returns a
        # compact period row.
        def simulate_period(window, balances)
          period_flows = ordered_flows_for(window[:key])

          income = BigDecimal("0")
          spending = BigDecimal("0")

          period_flows.each do |flow|
            converted = convert(flow, window)
            next if converted.nil? # held out per issue policy (e.g. missing FX)

            apply_flow(flow, converted, balances)
            case flow.category
            when "income" then income += converted
            when "spending" then spending += converted
            end
          end

          net_worth = household_net_worth(balances)

          metrics = Forecasts::Projection::Metrics.new(
            net_worth: net_worth,
            liquid_cash: balances[:liquid_cash],
            income: income,
            spending: spending,
            debt_balance: balances[:debt_balance],
            portfolio_value: balances[:portfolio_value],
            runway_days: runway_days(balances[:liquid_cash], spending, window),
            currency: reporting_currency
          )

          {
            key: window[:key],
            granularity: "month",
            starts_on: window[:starts_on].iso8601,
            ends_on: window[:ends_on].iso8601,
            currency: reporting_currency,
            metrics: metrics.to_h,
            proration: proration_for(window, period_flows),
            trace_ids: [],
            issue_ids: []
          }
        end

        # Flows whose date falls in the period, sorted by the spec's intra-period
        # flow order then by the ledger's stable ordering (date/sequence/key).
        def ordered_flows_for(period_key)
          ledger.for_period(period_key).sort_by do |flow|
            [ flow_rank(flow.category), flow.date, flow.sequence, flow.flow_key.to_s ]
          end
        end

        def flow_rank(category)
          FLOW_ORDER.fetch(category, 99)
        end

        # Mutates running balances for one flow. Income raises liquid cash;
        # spending lowers it. Later flow kinds (transfer/debt/portfolio) extend
        # this in their slices; this proof slice covers cash income + spending.
        def apply_flow(flow, amount, balances)
          case flow.category
          when "income"
            balances[:liquid_cash] += amount
          when "spending"
            balances[:liquid_cash] -= amount
          end
        end

        # Household net worth = liquid cash + portfolio value - debt balance.
        # Transfers between owned accounts net to zero here, satisfying the
        # invariant that intra-household transfers do not change net worth.
        def household_net_worth(balances)
          balances[:liquid_cash] + balances[:portfolio_value] - balances[:debt_balance]
        end

        # --- Runway ---------------------------------------------------------

        # Days of liquidity: liquid cash divided by an average daily spend for the
        # period. Integer days, decimal math. Two boundary cases:
        #   - No burn (spending <= 0) with positive cash is UNBOUNDED runway, not
        #     insolvency, so we return UNBOUNDED_RUNWAY_DAYS rather than 0. (A
        #     literal 0 would falsely signal "out of money" for any no-spend
        #     month.)
        #   - Non-positive cash means there is nothing to run on, so runway is 0
        #     regardless of burn.
        def runway_days(liquid_cash, spending, window)
          return 0 if liquid_cash <= 0
          return UNBOUNDED_RUNWAY_DAYS if spending <= 0

          days = BigDecimal(window[:ends_on].day.to_s)
          daily_spend = spending / days
          return UNBOUNDED_RUNWAY_DAYS if daily_spend <= 0

          (liquid_cash / daily_spend).floor
        end

        # --- Proration ------------------------------------------------------

        # Proration metadata for the period. Monthly periods inside the horizon
        # are full; the carry/trace layer uses `full_period` and `days_in_period`
        # to annotate partial-period assumptions per spec "Period Boundaries".
        def proration_for(window, _period_flows)
          days = window[:ends_on].day
          {
            days_in_period: days,
            full_period: true
          }
        end

        # --- Currency conversion --------------------------------------------

        # Converts a flow amount into the reporting currency, returning a
        # BigDecimal or nil. Same-currency flows pass through. Cross-currency
        # flows require a rate (rate + source + target + date) from the snapshot
        # FX table; a missing rate records a `missing_fx_rate` issue and returns
        # nil so the value is excluded/held per policy (no exception).
        def convert(flow, window)
          amount = BigDecimal(flow.amount)
          return amount if flow.currency == reporting_currency

          rate = fx_rate(flow.currency, reporting_currency, window)
          if rate.nil?
            record_missing_fx_issue(flow, window)
            return nil
          end

          amount * rate
        end

        # Resolves a rate for source->target effective on or before the period.
        # The snapshot FX table is a list of { from, to, date, rate }. We pick the
        # latest rate dated on or before the period end so a flow uses the freshest
        # applicable rate; an exact-or-prior match is required (no extrapolation).
        def fx_rate(from, to, window)
          candidates = fx_rates.select do |entry|
            entry[:from].to_s == from.to_s &&
              entry[:to].to_s == to.to_s &&
              rate_date(entry) &&
              rate_date(entry) <= window[:ends_on]
          end
          return nil if candidates.empty?

          best = candidates.max_by { |entry| rate_date(entry) }
          BigDecimal(best[:rate].to_s)
        end

        def fx_rates
          @fx_rates ||= Array(@snapshot[:fx_rates]).map { |entry| symbolize(entry) }
        end

        def rate_date(entry)
          parse_date(entry[:date])
        end

        # --- Issues ---------------------------------------------------------

        # Records a structured missing_fx_rate issue once per (currency, period).
        # Severity is `error` (output renders only with exclusions/held values).
        def record_missing_fx_issue(flow, window)
          key = [ flow.currency, reporting_currency, window[:key] ].join("|")
          return if @issue_keys.key?(key)

          @issue_keys[key] = true
          @issues << Forecasts::Projection::PlanIssue.new(
            code: "missing_fx_rate",
            severity: "error",
            source: "source_snapshot",
            period: window[:key],
            affected_entity_type: "assumption",
            affected_entity_id: flow.assumption_id,
            display_name: "Missing #{flow.currency} to #{reporting_currency} exchange rate",
            message_key: "forecasts.issues.missing_fx_rate",
            impact: missing_fx_impact,
            actions: %w[fetch_rates enter_fallback_rate exclude_account change_reporting_currency],
            debug_context: {
              from_currency: flow.currency,
              to_currency: reporting_currency,
              period_key: window[:key],
              rate_date: window[:ends_on].iso8601,
              flow_key: flow.flow_key,
              assumption_id: flow.assumption_id,
              policy: missing_fx_policy
            }
          )
        end

        # Default behaviour for a missing FX rate from the issue policy:
        # `issue_limited` (default) excludes the converted value; `hold` would
        # retain the prior known value. This slice excludes; the policy is carried
        # in debug context so later slices can hold instead.
        def missing_fx_policy
          (issue_policy[:missing_fx] || "issue_limited").to_s
        end

        def missing_fx_impact
          "Income and net worth are shown without this converted value for the affected period."
        end

        # --- Opening balances ------------------------------------------------

        # Seeds the running ledger from the snapshot's opening balances. Defaults
        # to zero so a snapshot without a given balance type simulates cleanly.
        def opening_balances
          opening = symbolize(@snapshot[:opening_balances] || {})
          {
            liquid_cash: to_decimal(opening[:liquid_cash]),
            debt_balance: to_decimal(opening[:debt_balance]),
            portfolio_value: to_decimal(opening[:portfolio_value])
          }
        end

        # --- Helpers --------------------------------------------------------

        def to_decimal(value)
          return BigDecimal("0") if value.nil? || value == ""

          BigDecimal(value.to_s)
        end

        def parse_date(value)
          return nil if value.nil? || value == ""
          return value if value.is_a?(Date)

          Date.parse(value.to_s)
        end

        def symbolize(value)
          Forecasts::Projection.deep_symbolize(value)
        end
    end
  end
end
