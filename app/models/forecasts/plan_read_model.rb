# frozen_string_literal: true

module Forecasts
  # Forecast V2 read model for the plan shell. Answers exactly ONE UI question:
  # "what plan is open and what shell should frame it?"
  #
  # It consumes a Forecasts::Plan and its current Forecasts::ProjectionCache row
  # (already loaded by the controller). It NEVER calls the engine, enqueues
  # recompute, mutates records, or parses the full projection-result JSON. It
  # surfaces only shell-level facts (spec "Read Model Contracts"):
  #
  #   plan identity, active lens + lens nav, scenario stack summary, projection
  #   freshness, privacy state, available actions, latest issue summary.
  #
  # It must NOT carry chart series, full assumption card details, editor form
  # values, or raw engine packets — those belong to the band / assumption /
  # editor read models.
  class PlanReadModel
    # The lenses (tabs) the V2 workspace frames the plan with. The default
    # first-viewport lens is the projection band.
    LENSES = %w[projection assumptions scenarios goals].freeze
    DEFAULT_LENS = "projection"

    # Shell-level actions the user can take on the plan as a whole. Per-card and
    # per-issue actions live on their own read models.
    DEFAULT_ACTIONS = %w[add_assumption add_scenario snapshot recompute].freeze

    attr_reader :plan, :cache, :active_lens

    # `cache` is the current Forecasts::ProjectionCache for the plan's live
    # scenario stack (may be nil before the first recompute completes).
    # `privacy_blurred` is the ephemeral privacy-mode toggle owned by the shell.
    def initialize(plan:, cache: nil, active_lens: DEFAULT_LENS, privacy_blurred: false)
      @plan = plan
      @cache = cache
      @active_lens = LENSES.include?(active_lens.to_s) ? active_lens.to_s : DEFAULT_LENS
      @privacy_blurred = privacy_blurred
    end

    def to_h
      {
        id: plan.id,
        name: plan.name,
        reporting_currency: plan.reporting_currency,
        plan_version: plan.current_plan_version,
        active_lens: active_lens,
        lenses: LENSES,
        scenario_stack: scenario_stack,
        freshness: freshness,
        privacy: privacy,
        actions: DEFAULT_ACTIONS,
        latest_issue_summary: latest_issue_summary
      }
    end

    private
      # Summary of the live scenario stack the open projection reflects. The
      # layer list is intentionally a bounded summary (key only); full layer
      # detail belongs to the compare/scenario read models.
      def scenario_stack
        {
          key: cache&.scenario_stack_key || "baseline",
          layers: stack_layers
        }
      end

      # The stack key is a sorted "+"-joined list of layer keys (baseline only for
      # this slice). Decoding it here avoids a per-layer query for the shell
      # summary.
      def stack_layers
        (cache&.scenario_stack_key || "baseline").split("+")
      end

      # Projection freshness for the shell badge: derived from the cache status +
      # finished_at. No engine call, no recompute — purely reading the cache row.
      def freshness
        return { state: "uncomputed", projected_at: nil } if cache.nil?

        {
          state: cache.status,
          projected_at: cache.finished_at&.iso8601
        }
      end

      # Ephemeral shell privacy state (the user's privacy-mode toggle). Canonical
      # plan truth lives on the server; this only frames the shell.
      def privacy
        { blurred: @privacy_blurred }
      end

      # The privacy-safe issue summary stored on the cache row (counts + codes
      # only — never financial detail). Falls back to an empty summary before the
      # first projection.
      def latest_issue_summary
        summary = Forecasts::Projection.deep_symbolize(cache&.issue_summary || {})
        {
          status: summary[:status] || (cache.nil? ? "uncomputed" : cache.status),
          issue_count: summary[:issue_count] || 0,
          codes: summary[:codes] || {}
        }
      end
  end
end
