# frozen_string_literal: true

module Forecasts
  # Loads everything ForecastsController#show needs, enforcing the spec §11 hard
  # rule: a GET runs NO engine work — it reads the persisted cache. The two
  # exceptions are structural, not per-request: first-ever visit (no plan / no
  # cache yet) and the §10 monthly self-heal (the cached projection is anchored
  # to an older month than today, so it re-anchors ONCE and is cached again).
  #
  # `today` is threaded by the controller (Date.current at the call site) so this
  # object stays clock-free and deterministic under test.
  class WorkspaceLoader
    BASELINE_STACK_KEY = Forecasts::Projection::PacketBuilder::BASELINE_SCENARIO_KEY

    attr_reader :family, :today, :plan, :cache

    def initialize(family:, today:)
      @family = family
      @today = today.to_date
    end

    # Returns self with `plan` and `cache` loaded. DefaultPlanBuilder runs ONLY
    # when the family has no active plan (spec §6.2 guarantee 1) — calling it
    # unconditionally would re-run derivation queries (and could write derived
    # assumption rows) on every GET, violating the §11 hard GET rule.
    def load
      @plan = existing_plan || Forecasts::DefaultPlanBuilder.new(family: family, as_of: today).build
      @cache = current_cache
      @cache = recompute! if @cache.nil? || anchored_to_older_month?
      self
    end

    private
      def existing_plan
        family.forecast_plans.active.ordered.first
      end

      def current_cache
        plan.forecast_projection_caches
          .current
          .where(scenario_stack_key: BASELINE_STACK_KEY, status: "fresh")
          .order(created_at: :desc)
          .first
      end

      # §10: the projection must be anchored at the current month. The anchor is
      # observable as the earliest persisted monthly period.
      def anchored_to_older_month?
        first_month = cache.forecast_projection_periods
          .where(granularity: "month")
          .minimum(:period_start_on)
        first_month.nil? || first_month < today.beginning_of_month
      end

      def recompute!
        snapshot = Forecasts::SourceSnapshotBuilder.new(plan: plan, as_of: today).build
        Forecasts::Projection::RecomputeCoordinator
          .new(plan: plan, source_snapshot: snapshot, anchor_on: today)
          .recompute
      end
  end
end
