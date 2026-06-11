# frozen_string_literal: true

module Forecasts
  # Forecast V2 read model for the main chart band. Answers exactly ONE UI
  # question: "what should the main chart and selected-period control show?"
  #
  # It consumes the current Forecasts::ProjectionCache plus its already-loaded,
  # indexed Forecasts::ProjectionPeriod rows — it NEVER calls the engine, mutates
  # records, or parses the full projection-result JSON. The chart series is sliced
  # straight from the indexed period metrics so first-viewport rendering needs no
  # per-period query (spec "Read Model Contracts", "UI Payload Contracts").
  #
  # It may include chart series, the selected metric, period keys, the selected
  # marker, and freshness labels. It must NOT include assumption editor data,
  # source-snapshot internals, or ActiveRecord records.
  class ProjectionBandReadModel
    DEFAULT_METRIC = "net_worth"

    # The metrics the chart's metric selector can switch between, in display
    # order. Mirrors the selected-period strip so the chart and inspector agree
    # on which metrics exist. Every key here resolves to `forecasts.metrics.<key>`
    # in the client copy table.
    CHARTABLE_METRICS = SelectedPeriodReadModel::METRIC_KEYS

    attr_reader :cache, :periods, :selected_metric, :selected_marker

    # `periods` must already be loaded (e.g. `cache.forecast_projection_periods
    # .ordered.to_a`). `selected_period_key` defaults to the first period; the
    # selected metric defaults to net worth.
    def initialize(cache:, periods:, selected_period_key: nil, selected_metric: nil)
      @cache = cache
      @periods = periods
      @selected_metric = (selected_metric || DEFAULT_METRIC).to_s
      @selected_marker = selected_period_key || periods.first&.period_key
    end

    def to_h
      {
        selected_metric: selected_metric,
        selected_marker: selected_marker,
        available_metrics: available_metrics,
        period_keys: period_keys,
        series: series,
        metric_series: metric_series,
        freshness: freshness
      }
    end

    private
      def period_keys
        periods.map(&:period_key)
      end

      # The chartable metric keys actually present in the indexed period rows, in
      # display order. The selector only offers metrics with data so switching
      # never points at an empty series. Always includes the selected metric.
      def available_metrics
        present = CHARTABLE_METRICS.select do |key|
          periods.any? { |period| (period.metrics || {}).key?(key) }
        end
        present.include?(selected_metric) ? present : ([ selected_metric ] + present)
      end

      # One compact point per period: the period key plus the selected metric's
      # decimal-string value read directly from the indexed row's metrics jsonb.
      # No float conversion, no formatting — the client formats for display.
      def series
        series_for(selected_metric)
      end

      # Every chartable metric's compact series, keyed by metric. The chart's
      # metric selector re-points to one of these LOCALLY (zero network) — the
      # period rows already carry all metrics, so this adds no per-period query.
      def metric_series
        available_metrics.each_with_object({}) do |key, acc|
          acc[key] = series_for(key)
        end
      end

      def series_for(metric_key)
        periods.map do |period|
          metrics = period.metrics || {}
          {
            period_key: period.period_key,
            value: metrics[metric_key]
          }
        end
      end

      # Freshness label sourced from the cache row only (status + finished_at).
      def freshness
        return { state: "uncomputed", projected_at: nil } if cache.nil?

        {
          state: cache.status,
          projected_at: cache.finished_at&.iso8601
        }
      end
  end
end
