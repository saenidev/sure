module Forecast
  # Read-only PORO that derives deterministic, percentile-STYLE bands from the
  # already-computed ForecastRun rows of ONE comparison ForecastRunGroup
  # (baseline / downside / upside / custom stacks — the same inputs
  # `ComparisonSeriesBuilder` reads).
  #
  # IMPORTANT: these are deterministic SCENARIO bands, NOT statistical
  # percentiles and NOT Monte Carlo. Per the design spec: "The UI can show these
  # as bands or comparisons, but they are deterministic scenario bands, not
  # statistical percentiles." For each calendar month we simply take the min /
  # (lower-)median / max of a metric ACROSS the deterministic stacks and label
  # them `deterministic_low` / `deterministic_mid` / `deterministic_high`. There
  # is NO engine recompute, NO RNG, and NO wall-clock read — the same persisted
  # rows always produce the same bands.
  #
  # Like the other read-model builders, this NEVER touches `Forecast::Engine`. It
  # only reads the immutable ForecastMonth rows the Runner already persisted, so
  # callers SHOULD pass runs with `forecast_months` eager-loaded to avoid N+1.
  #
  # Determinism guarantees:
  #   * Failed runs (a stack that errored mid-group) are EXCLUDED so they cannot
  #     poison the min/max — a missing stack must never read as a zero band edge.
  #   * Bands span only the months COMMON to every contributing stack (the
  #     intersection of `period_start_on`), so a short/long stack cannot widen a
  #     band over months it never projected. When stacks disagree on coverage the
  #     output carries a `note` explaining the trimmed span.
  #   * Points are ordered by `period_start_on`.
  #   * `low`/`high` each record the stack key that supplied them (explainability),
  #     using a stable stack ordering with the stack key as the tie-breaker so the
  #     attributed source never reshuffles between renders.
  class DistributionBandBuilder
    BASELINE_STACK_KEY = "baseline".freeze

    # Metrics we band. Each maps to a ForecastMonth decimal column.
    METRICS = %i[net_worth cash_balance debt_balance].freeze

    # One banded month for one metric. `*_stack_key` attribute the chosen low/high
    # to the stack that supplied them; `mid` is a deterministic lower-median and is
    # also a real stack value, so its source is recorded too.
    BandPoint = Data.define(
      :period_start_on,
      :period_end_on,
      :currency,
      :deterministic_low,
      :deterministic_mid,
      :deterministic_high,
      :low_stack_key,
      :mid_stack_key,
      :high_stack_key,
      :contributing_stack_keys
    )

    # The full set of bands for one metric across the common horizon.
    Band = Data.define(:metric, :currency, :points, :note)

    # `runs` is the ForecastRun collection of one group, ideally with
    # `forecast_months` eager-loaded.
    def initialize(runs:)
      @runs = Array(runs)
    end

    # Band for a single metric (one of METRICS). Returns a Band whose `points` are
    # ordered by `period_start_on`; empty when there are no contributing stacks or
    # no common months.
    def band(metric)
      metric = metric.to_sym
      raise ArgumentError, "unknown band metric: #{metric}" unless METRICS.include?(metric)

      bands.fetch(metric)
    end

    # All bands keyed by metric symbol. Memoized so repeated reads (e.g. one per
    # chart lane) share a single pass over the persisted rows.
    def bands
      @bands ||= METRICS.index_with { |metric| build_band(metric) }
    end

    # True when at least one contributing stack with common months exists.
    def any?
      common_period_starts.any? && contributing_stacks.any?
    end

    private
      attr_reader :runs

      # Stacks that actually contribute to the bands: completed (not failed) runs
      # that carry at least one ForecastMonth, ordered stably (baseline first,
      # then by stack key) so attribution and notes are deterministic.
      def contributing_stacks
        @contributing_stacks ||= runs
          .reject { |run| run.status == "failed" }
          .map { |run| [ run, months_for(run) ] }
          .reject { |(_run, months)| months.empty? }
          .sort_by { |(run, _months)| [ run.scenario_stack_key == BASELINE_STACK_KEY ? 0 : 1, run.scenario_stack_key.to_s ] }
      end

      # The months common to EVERY contributing stack, by period_start_on, ordered
      # ascending. Intersecting guarantees a band edge is always backed by a real
      # value from every stack, so a shorter or longer stack cannot distort it.
      def common_period_starts
        @common_period_starts ||= begin
          per_stack_starts = contributing_stacks.map { |(_run, months)| months.map(&:period_start_on) }
          return [] if per_stack_starts.empty?

          per_stack_starts.reduce(:&).uniq.sort
        end
      end

      # True when the contributing stacks do not all cover the same months, so the
      # band span was trimmed to the intersection. Drives the explanatory `note`.
      def coverage_differs?
        return false if contributing_stacks.empty?

        counts = contributing_stacks.map { |(_run, months)| months.size }
        counts.uniq.size > 1 || counts.first != common_period_starts.size
      end

      def build_band(metric)
        starts = common_period_starts
        points = starts.map { |period_start| band_point(metric, period_start) }

        Band.new(
          metric: metric,
          currency: currency,
          points: points,
          note: band_note(points)
        )
      end

      # For one metric and one common month, gather (stack_key, value) from every
      # contributing stack, then derive deterministic low/mid/high. Sorting by
      # value with the stack key as the tie-breaker makes the chosen source stable
      # when two stacks share a value.
      def band_point(metric, period_start)
        samples = contributing_stacks.map do |(run, months)|
          month = months.find { |m| m.period_start_on == period_start }
          [ run.scenario_stack_key, month.public_send(metric).to_d, month.period_end_on ]
        end

        period_end = samples.first[2]
        ordered = samples.sort_by { |(stack_key, value, _end)| [ value, stack_key.to_s ] }
        low = ordered.first
        high = ordered.last
        mid = ordered[(ordered.size - 1) / 2] # lower-median: deterministic, real stack value

        BandPoint.new(
          period_start_on: period_start,
          period_end_on: period_end,
          currency: currency,
          deterministic_low: low[1],
          deterministic_mid: mid[1],
          deterministic_high: high[1],
          low_stack_key: low[0],
          mid_stack_key: mid[0],
          high_stack_key: high[0],
          contributing_stack_keys: samples.map(&:first)
        )
      end

      def band_note(points)
        return I18n.t("forecasts.distribution.empty_band_note") if points.empty?
        return I18n.t("forecasts.distribution.trimmed_to_common_months_note") if coverage_differs?

        nil
      end

      def currency
        contributing_stacks.first&.first&.currency || runs.first&.currency
      end

      # Months for a run, preferring an eager-loaded association to avoid N+1.
      def months_for(run)
        if run.forecast_months.loaded?
          run.forecast_months.to_a.sort_by(&:period_start_on)
        else
          run.forecast_months.order(:period_start_on).to_a
        end
      end
  end
end
