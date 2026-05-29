module Forecast
  # Compares a freshly completed forecast run group against the family's
  # previous completed group to decide whether the projection moved enough to be
  # worth surfacing for human (or later Hermes) review.
  #
  # Used by ForecastMarketCloseJob: after market data is imported and a fresh
  # group is generated, we only KEEP it (flag its draft review) when the
  # movement is material. This keeps the market-close cadence from generating
  # daily noise when nothing meaningfully changed.
  #
  # The comparison is intentionally read-only: it reads each group's BASELINE
  # run's first projected day (the "today" snapshot the engine anchors on) and
  # compares portfolio value, net worth, debt, and cash runway. Thresholds come
  # from Rails.configuration.x.forecast.* (see config/initializers/forecast.rb)
  # and are compared against the ABSOLUTE change, so a drop is as material as a
  # gain.
  #
  # No engine math is recomputed here — only persisted ForecastDay columns are
  # read. Both groups are reached through `family.forecast_run_groups`, so the
  # comparison can never leak across families.
  class MaterialMovement
    BASELINE_STACK_KEY = "baseline".freeze

    Result = Struct.new(:material, :reasons, :metrics, keyword_init: true) do
      def material?
        material
      end
    end

    def self.thresholds
      forecast = Rails.configuration.x.forecast
      {
        portfolio_change_pct: forecast.material_portfolio_change_pct,
        net_worth_change_pct: forecast.material_net_worth_change_pct,
        debt_change_pct: forecast.material_debt_change_pct,
        cash_runway_change_days: forecast.material_cash_runway_change_days,
        on_missing_baseline: forecast.material_on_missing_baseline
      }
    end

    # current_group: the freshly completed ForecastRunGroup under evaluation.
    # previous_group: the family's prior completed group (or nil for the first run).
    def initialize(current_group:, previous_group:, thresholds: self.class.thresholds)
      @current_group = current_group
      @previous_group = previous_group
      @thresholds = thresholds
    end

    def call
      current_day = baseline_first_day(current_group)

      # No usable current snapshot (e.g. a completed group with no projected
      # days) — nothing to compare, so do not flag as material.
      if current_day.nil?
        return Result.new(material: false, reasons: [], metrics: {})
      end

      previous_day = previous_group && baseline_first_day(previous_group)

      if previous_day.nil?
        return Result.new(
          material: thresholds.fetch(:on_missing_baseline),
          reasons: thresholds.fetch(:on_missing_baseline) ? [ "no_previous_group" ] : [],
          metrics: { "portfolio_value" => to_f(current_day.portfolio_value) }
        )
      end

      reasons = []
      metrics = {}

      evaluate_pct(reasons, metrics, "portfolio_value", current_day.portfolio_value, previous_day.portfolio_value, thresholds.fetch(:portfolio_change_pct))
      evaluate_pct(reasons, metrics, "net_worth", current_day.net_worth, previous_day.net_worth, thresholds.fetch(:net_worth_change_pct))
      evaluate_pct(reasons, metrics, "debt_balance", current_day.debt_balance, previous_day.debt_balance, thresholds.fetch(:debt_change_pct))
      evaluate_abs_days(reasons, metrics, "cash_runway_days", current_day.cash_runway_days, previous_day.cash_runway_days, thresholds.fetch(:cash_runway_change_days))

      Result.new(material: reasons.any?, reasons: reasons, metrics: metrics)
    end

    private
      attr_reader :current_group, :previous_group, :thresholds

      # The first projected day of the group's baseline run. Falls back to any
      # completed run when the baseline stack itself did not complete (mirrors
      # Workspace#baseline_run). Reads the eager-loadable association.
      def baseline_first_day(group)
        run = baseline_run(group)
        return nil if run.nil?

        run.forecast_days.min_by(&:date)
      end

      def baseline_run(group)
        runs = group.forecast_runs.to_a
        runs.find { |r| r.scenario_stack_key == BASELINE_STACK_KEY && r.completed? } ||
          runs.find(&:completed?)
      end

      def evaluate_pct(reasons, metrics, key, current_value, previous_value, threshold_pct)
        current = to_f(current_value)
        previous = to_f(previous_value)

        change = current - previous
        base = previous.abs

        pct =
          if base.zero?
            # Going from zero to non-zero is an unbounded % change; treat any
            # non-zero movement off a zero base as fully material.
            change.zero? ? 0.0 : Float::INFINITY
          else
            change / base
          end

        metrics["#{key}_from"] = previous
        metrics["#{key}_to"] = current
        metrics["#{key}_change_pct"] = pct.finite? ? pct.round(6) : nil

        reasons << "#{key}_change" if pct.abs >= threshold_pct.to_f
      end

      def evaluate_abs_days(reasons, metrics, key, current_value, previous_value, threshold_days)
        # cash_runway_days can be nil (unbounded runway). When either side is
        # nil we cannot compute a delta, so we do not flag on it.
        return if current_value.nil? || previous_value.nil?

        change_days = (current_value.to_i - previous_value.to_i).abs
        metrics["#{key}_from"] = previous_value.to_i
        metrics["#{key}_to"] = current_value.to_i
        metrics["#{key}_change_days"] = change_days

        reasons << "#{key}_change" if change_days >= threshold_days.to_i
      end

      def to_f(value)
        value.nil? ? 0.0 : value.to_f
      end
  end
end
