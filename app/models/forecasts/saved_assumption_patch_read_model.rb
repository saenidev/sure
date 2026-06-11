# frozen_string_literal: true

module Forecasts
  # Forecast V2 read model for a SAVED assumption patch. Answers exactly ONE UI
  # question: "after committing one assumption save, which scoped regions changed
  # and what are the new version tokens?"
  #
  # It is the typed changed-region payload the salary save endpoint (C8) returns
  # INSTEAD of a full workspace reload (spec "Patch budget": "Assumption save may
  # patch the saved card, selected-period inspector, metric strip, issue panel,
  # freshness indicator, and chart data token"; "Save endpoints": "typed JSON
  # changed-region payload ... must not trigger a full-page browser navigation").
  #
  # It consumes ALREADY-LOADED rows handed in by the controller — the committed
  # plan + assumption, and (when a synchronous recompute produced one) the current
  # projection cache with its seeded period row (traces embedded). It NEVER calls the
  # engine, enqueues recompute, mutates records, or parses the full
  # projection-result JSON (spec "Read Model Contracts"). The regions are composed
  # from the same per-surface read models the first viewport uses, so the client
  # patches each region by its C3 data-testid key without a workspace re-render.
  #
  # When the recompute is deferred to a background job (over budget), `cache` is
  # the recomputing cache (no fresh periods yet): the saved card still reflects
  # committed truth and the projection regions carry the recomputing freshness
  # state (spec "Live Recompute Model": "the card still updates and the projection
  # regions enter a visible stale/recomputing state").
  class SavedAssumptionPatchReadModel
    attr_reader :assumption, :plan, :cache, :period

    # `assumption` + `plan` are the committed records. `cache` is the current
    # projection cache for the new plan version (fresh after a sync recompute, or
    # a recomputing marker when deferred; may be nil only if no cache exists yet).
    # `period` is the seeded selected-period row (its embedded `traces` blob
    # carries the explanation traces) for the selected-period inspector / metric
    # strip, already loaded by the controller (nil when projection output is not
    # ready).
    def initialize(assumption:, plan:, cache: nil, period: nil)
      @assumption = assumption
      @plan = plan
      @cache = cache
      @period = period
    end

    def to_h
      {
        saved_card: saved_card,
        selected_period: selected_period,
        metric_strip: metric_strip,
        issues: issues,
        freshness: freshness,
        chart_data_token: chart_data_token,
        version_tokens: version_tokens
      }
    end

    private
      # The committed saved card — built by the assumption-rail read model from the
      # single committed record, so the card reflects SERVER truth, never the
      # client's calculated state (spec "Live Recompute Model").
      def saved_card
        Forecasts::AssumptionGroupReadModel.new(
          assumptions: [ assumption ],
          active_assumption_ids: active_assumption_ids
        ).to_h.dig(:groups, 0, :cards, 0)
      end

      # The selected-period inspector region (metric strip lives inside it). Nil
      # when projection output is not yet ready (deferred recompute) so the client
      # keeps the prior inspector and shows the recomputing badge.
      def selected_period_payload
        return @selected_period_payload if defined?(@selected_period_payload)

        @selected_period_payload =
          if period.nil?
            nil
          else
            Forecasts::SelectedPeriodReadModel.new(
              period: period, cache: cache
            ).to_h
          end
      end

      def selected_period
        selected_period_payload
      end

      # The metric strip region, sliced from the selected-period payload (one
      # source of truth — no second read). Empty until projection output is ready.
      def metric_strip
        selected_period_payload&.fetch(:metrics, []) || []
      end

      # The issue panel region: the privacy-safe issue summary codes stored on the
      # cache row, mapped through the stable IssueCatalog to structured, localized
      # issues (severity + message_key title + remediation actions) and shaped by
      # the IssueReadModel (no per-issue query) — consistent with the first-viewport
      # issue panel.
      def issues
        codes = cache&.issue_summary&.dig("codes") || {}
        codes.keys.map do |code|
          Forecasts::IssueReadModel.new(
            issue: Forecasts::IssueCatalog.issue_hash(code)
          ).to_h
        end
      end

      # The freshness region: cache status + finished_at. "recomputing" when the
      # recompute was deferred to a background job; "fresh" after a sync recompute.
      def freshness
        return { state: "uncomputed", projected_at: nil } if cache.nil?

        { state: cache.status, projected_at: cache.finished_at&.iso8601 }
      end

      # The chart data token: a stable cache key the client uses to invalidate +
      # re-fetch the chart band only when the underlying projection changed (it
      # changes whenever the plan version, scenario stack, or result hash changes).
      # It carries NO chart series — the band re-fetches lazily; this is just the
      # cache-busting token (spec "Patch budget": save may patch the "chart data
      # token", not the full band).
      def chart_data_token
        return nil if cache.nil?

        "#{cache.scenario_stack_key}:v#{cache.plan_version}:#{cache.projection_result_hash}"
      end

      # The version tokens the client folds into its workspace store so dependent
      # regions recompute their cache keys: the committed plan version + the saved
      # assumption's optimistic lock version (spec "Live Recompute Model").
      def version_tokens
        {
          plan_version: plan.current_plan_version,
          lock_version: assumption.lock_version,
          scenario_stack_key: cache&.scenario_stack_key || "baseline"
        }
      end

      def active_assumption_ids
        Array(period&.active_assumption_ids)
      end
  end
end
