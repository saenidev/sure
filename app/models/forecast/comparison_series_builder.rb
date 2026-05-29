module Forecast
  # Read-only PORO that turns the *several* completed ForecastRun rows of one
  # comparison ForecastRunGroup into one `Series` per scenario stack, so the
  # comparison view can render them side by side (or each as its own line).
  #
  # Like `Forecast::SeriesBuilder`, it NEVER touches `Forecast::Engine` or
  # recomputes any projection math — it only reads the immutable ForecastMonth
  # (or ForecastDay) rows the Runner already persisted. Callers MUST pass runs
  # with their `forecast_months` (or `forecast_days`) eager-loaded so building
  # issues no per-row queries (no N+1 across stacks x 36 months).
  #
  # The output is an ordered array of `Stack` structs — one per scenario stack
  # key, ordered stably so the comparison table/chart columns never reshuffle
  # between renders (baseline first, then the rest by stack key). Each carries:
  #   * key                -> the run's scenario_stack_key ("baseline" or a hash)
  #   * label              -> a humanized name from the stack snapshot
  #   * status             -> the run's status (completed/failed/...)
  #   * net_worth_series   -> a `Series` of monthly net_worth, or nil if too few
  #   * end_cash / end_net_worth / end_debt -> end-of-horizon Money metrics
  #   * feasibility_status -> the run's pass/warn/blocked/unknown
  #   * risk_flag_types    -> distinct risk-flag type tokens for the run
  #
  # A failed run (a stack that errored mid-group) still yields a Stack so the
  # view can surface its failure distinctly without dropping the stacks that
  # succeeded — partial failure never blanks the comparison.
  class ComparisonSeriesBuilder
    BASELINE_STACK_KEY = "baseline".freeze

    Stack = Data.define(
      :key,
      :label,
      :status,
      :failed,
      :currency,
      :net_worth_series,
      :end_cash,
      :end_net_worth,
      :end_debt,
      :feasibility_status,
      :risk_flag_types
    )

    # `runs` is the collection of ForecastRun rows in the group, ideally with
    # `forecast_months` eager-loaded. `currency` falls back per-run.
    def initialize(runs:)
      @runs = Array(runs)
    end

    # One Stack per scenario stack key, ordered stably (baseline first, then by
    # key). Memoized so the table and chart share one build.
    def stacks
      @stacks ||= ordered_runs.map { |run| build_stack(run) }
    end

    # Convenience: just the per-stack net-worth series, keyed by stack key. Lets
    # a multi-line chart (or per-stack sparklines) iterate without re-deriving.
    def net_worth_series_by_key
      stacks.index_by(&:key).transform_values(&:net_worth_series)
    end

    def any?
      stacks.any?
    end

    private
      attr_reader :runs

      # Stable ordering: baseline always first, then remaining runs by their
      # scenario_stack_key so column order is deterministic across renders.
      def ordered_runs
        runs.sort_by do |run|
          [ run.scenario_stack_key == BASELINE_STACK_KEY ? 0 : 1, run.scenario_stack_key.to_s ]
        end
      end

      def build_stack(run)
        months = months_for(run)
        last_month = months.last
        currency = run.currency

        Stack.new(
          key: run.scenario_stack_key,
          label: label_for(run),
          status: run.status,
          failed: run.status == "failed",
          currency: currency,
          net_worth_series: net_worth_series(run, months),
          end_cash: last_month && Money.new(last_month.cash_balance, currency),
          end_net_worth: last_month && Money.new(last_month.net_worth, currency),
          end_debt: last_month && Money.new(last_month.debt_balance, currency),
          feasibility_status: run.feasibility_status,
          risk_flag_types: risk_flag_types_for(run)
        )
      end

      # Build the 36-month net-worth series for one run via the existing
      # read-only SeriesBuilder, passing the eager-loaded months so no query is
      # issued. Returns nil for a failed/empty run (fewer than two months).
      def net_worth_series(run, months)
        return nil if months.size < 2

        Forecast::SeriesBuilder.new(run, months: months).net_worth_series
      end

      # Months for a run, preferring an eager-loaded association to avoid N+1.
      # If the association is already loaded we sort in Ruby; otherwise we issue
      # one ordered query for this run.
      def months_for(run)
        if run.forecast_months.loaded?
          run.forecast_months.to_a.sort_by(&:period_start_on)
        else
          run.forecast_months.order(:period_start_on).to_a
        end
      end

      # Humanized label for a stack: the baseline key gets the i18n baseline
      # label; otherwise we join the scenario names from the snapshot, falling
      # back to the raw key when no snapshot is present.
      def label_for(run)
        return I18n.t("forecasts.comparison.baseline_label") if run.scenario_stack_key == BASELINE_STACK_KEY

        scenarios = run.scenario_stack_snapshot.is_a?(Hash) ? Array(run.scenario_stack_snapshot["scenarios"]) : []
        names = scenarios.map { |scenario| scenario["name"] }.compact_blank
        names.any? ? names.join(" + ") : run.scenario_stack_key
      end

      # Distinct risk-flag type tokens for a run, collapsing hash/string flags to
      # their type so the table lists each kind once. Read straight from the
      # persisted run; no engine recompute.
      def risk_flag_types_for(run)
        Array(run.risk_flags).map { |flag| flag.is_a?(Hash) ? (flag["type"] || flag[:type]) : flag }
          .compact_blank
          .uniq
          .map(&:to_s)
      end
  end
end
