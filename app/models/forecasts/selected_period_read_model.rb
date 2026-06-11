# frozen_string_literal: true

require "bigdecimal"
require "bigdecimal/util"

module Forecasts
  # Forecast V2 read model for the selected month/year. Answers exactly ONE UI
  # question: "what explains the currently selected period?"
  #
  # It is loaded from the indexed Forecasts::ProjectionPeriod row plus its
  # Forecasts::ProjectionTrace rows — NEVER by parsing the full projection-result
  # JSON (spec "Read Model Contracts": "SelectedPeriodReadModel reads period/trace
  # rows (not full JSON)"). The coordinator already indexed both row sets; this
  # read model just shapes them into the selected-period UI payload.
  #
  # It may include the metric strip, active assumption IDs, trace-backed
  # explanation lines, period issues, and freshness state. It must NOT include the
  # full plan payload, recompute commands, or raw trace-graph dumps. It never
  # calls the engine, enqueues recompute, mutates records, or queries per trace /
  # per issue.
  class SelectedPeriodReadModel
    # The metric strip order mirrors the engine's money metric ordering plus the
    # integer runway. Each entry carries an i18n `label_key`, never a formatted
    # label, so the client owns presentation.
    METRIC_KEYS = %w[net_worth liquid_cash income spending debt_balance portfolio_value runway_days].freeze

    # Maps a stored trace category onto the explanation-line kind the UI groups by
    # (income shows as income; spending shows as an expense line).
    EXPLANATION_KIND_FOR_CATEGORY = {
      "income" => "income",
      "spending" => "expense"
    }.freeze

    attr_reader :period, :traces, :cache

    # `period` is one Forecasts::ProjectionPeriod row; `traces` are the already
    # loaded Forecasts::ProjectionTrace rows for that period; `cache` supplies the
    # freshness label only.
    def initialize(period:, traces:, cache: nil)
      @period = period
      @traces = traces
      @cache = cache
    end

    def to_h
      {
        period_key: period.period_key,
        granularity: period.granularity,
        selected_metric: ProjectionBandReadModel::DEFAULT_METRIC,
        metrics: metric_strip,
        active_assumption_ids: active_assumption_ids,
        explanation: explanation_lines,
        issues: issue_lines,
        freshness: freshness
      }
    end

    private
      # The metric strip is built from the indexed period row's metrics jsonb.
      # Money values stay decimal strings; runway stays an integer. Each entry
      # exposes an i18n label key (`forecasts.metrics.<key>`) for the client.
      def metric_strip
        metrics = period.metrics || {}
        METRIC_KEYS.map do |key|
          {
            key: key,
            label_key: "forecasts.metrics.#{key}",
            value: metrics[key]
          }
        end
      end

      # The active assumption ids the coordinator stored on the period row — no
      # re-derivation from traces, no query.
      def active_assumption_ids
        Array(period.active_assumption_ids)
      end

      # One explanation line per trace row, in the coordinator's stored
      # display_order. Amount is the trace's decimal-string value; the client
      # renders the i18n `explanation_key`. This is the trace-backed explanation
      # the spec requires (rendered from traces, not chart series).
      def explanation_lines
        traces.map do |trace|
          {
            kind: EXPLANATION_KIND_FOR_CATEGORY.fetch(trace.category, trace.category),
            amount: money_string(trace.amount),
            currency: trace.currency,
            direction: trace.direction,
            explanation_key: trace.explanation_key,
            source: "trace"
          }
        end
      end

      # Serializes a stored decimal trace amount as a fixed two-minor-unit decimal
      # string, matching the engine's period-metric money serialization. This is
      # canonical serialization, not UI formatting — there is no currency symbol,
      # grouping, or locale applied; the client formats for display.
      def money_string(amount)
        return nil if amount.nil?

        decimal = amount.is_a?(BigDecimal) ? amount : BigDecimal(amount.to_s)
        whole, frac = decimal.round(2, BigDecimal::ROUND_HALF_UP).to_s("F").split(".")
        "#{whole}.#{(frac || '').ljust(2, '0')[0, 2]}"
      end

      # Privacy-safe period issues: only the issue codes the coordinator stored on
      # the period row (no financial detail, no UUIDs). Severity is inferred from
      # the issue code catalog default for the proof slice.
      def issue_lines
        Array(period.issue_codes).map do |code|
          {
            code: code,
            severity: "limited",
            message_key: "forecasts.issues.#{code}"
          }
        end
      end

      # Freshness label from the cache row only.
      def freshness
        return { state: "uncomputed", projected_at: nil } if cache.nil?

        {
          state: cache.status,
          projected_at: cache.finished_at&.iso8601
        }
      end
  end
end
