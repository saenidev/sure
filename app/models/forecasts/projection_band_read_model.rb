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
        period_keys: period_keys,
        series: series,
        freshness: freshness
      }
    end

    private
      def period_keys
        periods.map(&:period_key)
      end

      # One compact point per period: the period key plus the selected metric's
      # decimal-string value read directly from the indexed row's metrics jsonb.
      # No float conversion, no formatting — the client formats for display.
      def series
        periods.map do |period|
          metrics = period.metrics || {}
          {
            period_key: period.period_key,
            value: metrics[selected_metric]
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
