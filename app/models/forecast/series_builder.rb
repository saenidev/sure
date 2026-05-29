module Forecast
  # Read-only PORO that turns a completed ForecastRun's persisted output rows
  # into `Series`-shaped data the existing `time-series-chart` Stimulus
  # controller can render (the same contract the dashboard net-worth chart uses:
  # date + Money value points, with a `trend` per point).
  #
  # It NEVER touches Forecast::Engine or recomputes any projection math — it only
  # reads the immutable ForecastDay / ForecastMonth rows that the Runner already
  # persisted. Callers must eager-load `forecast_days` / `forecast_months` (or
  # pass pre-loaded arrays) so rendering issues no per-row queries.
  #
  # Produced series:
  #   * cash_runway_series  -> 90 daily cash_balance points
  #   * liquid_runway_series -> 90 daily liquid_balance points
  #   * net_worth_series    -> 36 monthly net_worth points (uses ForecastMonth#net_worth, not cash)
  #
  # Series#from_raw_values requires at least two points, so a run with zero (or a
  # single) day/month yields a nil series. Views check `series&.any?` and fall
  # back to the shared `data_not_available` message instead of an empty SVG.
  class SeriesBuilder
    # `run` is a completed ForecastRun. `days` / `months` may be passed in
    # already loaded (e.g. by the workspace) to avoid re-querying; otherwise they
    # are loaded ordered chronologically.
    def initialize(run, days: nil, months: nil)
      @run = run
      @days = days
      @months = months
    end

    # 90-row daily cash balance series (the cash-runway line).
    def cash_runway_series
      daily_series(:cash_balance, favorable_direction: "up")
    end

    # 90-row daily liquid balance series (the second runway line).
    def liquid_runway_series
      daily_series(:liquid_balance, favorable_direction: "up")
    end

    # 36-row monthly net-worth series. Reads ForecastMonth#net_worth (NOT cash).
    def net_worth_series
      monthly_series(:net_worth, favorable_direction: "up")
    end

    # Distinct, persisted day-level risk-flag type tokens (e.g. "negative_cash",
    # "cash_shortfall") across the horizon. Read straight from ForecastDay#risk_flags
    # — no engine math is recomputed. Used to annotate the runway chart.
    def runway_risk_flag_types
      days.flat_map { |day| Array(day.risk_flags) }
        .map { |flag| flag.is_a?(Hash) ? (flag["type"] || flag[:type]) : flag }
        .compact_blank
        .uniq
        .map(&:to_s)
    end

    # True when any projected day dips into negative cash. Drives an inline risk
    # note even when the engine did not stamp a discrete risk flag.
    def negative_cash?
      days.any? { |day| day.cash_balance.to_d.negative? }
    end

    # True when there is anything worth annotating on the runway chart.
    def runway_risk?
      negative_cash? || runway_risk_flag_types.any?
    end

    private
      attr_reader :run

      def currency
        run.currency
      end

      def days
        @days ||= run.forecast_days.order(:date).to_a
      end

      def months
        @months ||= run.forecast_months.order(:period_start_on).to_a
      end

      def daily_series(column, favorable_direction:)
        build_series(
          rows: days,
          date_method: :date,
          column: column,
          interval: "1 day",
          favorable_direction: favorable_direction
        )
      end

      def monthly_series(column, favorable_direction:)
        build_series(
          rows: months,
          date_method: :period_start_on,
          column: column,
          interval: "1 month",
          favorable_direction: favorable_direction
        )
      end

      # Builds a `Series` from persisted rows, wrapping each value as a Money in
      # the run's currency so the chart's axis labels / tooltips reuse server-side
      # Money formatting. Returns nil when there are fewer than two points so the
      # view renders the data_not_available fallback rather than an empty chart.
      def build_series(rows:, date_method:, column:, interval:, favorable_direction:)
        return nil if rows.size < 2

        values = [ nil, *rows ].each_cons(2).map do |previous_row, current_row|
          current_value = Money.new(current_row.public_send(column), currency)
          previous_value = previous_row ? Money.new(previous_row.public_send(column), currency) : nil

          Series::Value.new(
            date: current_row.public_send(date_method),
            date_formatted: I18n.l(current_row.public_send(date_method), format: :long),
            value: current_value,
            trend: Trend.new(
              current: current_value,
              previous: previous_value,
              favorable_direction: favorable_direction
            )
          )
        end

        Series.new(
          start_date: rows.first.public_send(date_method),
          end_date: rows.last.public_send(date_method),
          interval: interval,
          values: values,
          favorable_direction: favorable_direction
        )
      end
  end
end
