# frozen_string_literal: true

require "test_helper"

class Forecasts::WorkspaceLoaderTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
  end

  test "first load creates a default plan and a fresh projection" do
    assert_difference -> { @family.forecast_plans.count }, 1 do
      loader = Forecasts::WorkspaceLoader.new(family: @family, today: Date.new(2026, 6, 15)).load
      assert loader.plan.persisted?
      assert loader.cache.fresh?
      assert_operator loader.cache.forecast_projection_periods.count, :>, 0
    end
  end

  test "second load reuses the plan and the cache without recomputing" do
    first = Forecasts::WorkspaceLoader.new(family: @family, today: Date.new(2026, 6, 15)).load
    second = nil
    assert_no_difference -> { Forecasts::ProjectionCache.count } do
      second = Forecasts::WorkspaceLoader.new(family: @family, today: Date.new(2026, 6, 20)).load
    end
    assert_equal first.cache.id, second.cache.id
  end

  test "loading an existing plan performs no derivation writes" do
    # Spec §11 hard GET rule + §6.2 guarantee 1: once a plan exists, a load must
    # never run derivation or create/modify assumption rows.
    Forecasts::WorkspaceLoader.new(family: @family, today: Date.new(2026, 6, 15)).load
    assert_no_difference -> { Forecasts::Assumption.count } do
      Forecasts::WorkspaceLoader.new(family: @family, today: Date.new(2026, 6, 20)).load
    end
  end

  test "a new month self-heals by re-anchoring the projection" do
    first = Forecasts::WorkspaceLoader.new(family: @family, today: Date.new(2026, 6, 15)).load
    second = Forecasts::WorkspaceLoader.new(family: @family, today: Date.new(2026, 8, 3)).load

    refute_equal first.cache.id, second.cache.id
    assert_equal Date.new(2026, 8, 1),
      second.cache.forecast_projection_periods.where(granularity: "month").minimum(:period_start_on)
  end
end
