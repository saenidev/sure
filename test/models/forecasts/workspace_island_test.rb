# frozen_string_literal: true

require "test_helper"

class Forecasts::WorkspaceIslandTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @loader = Forecasts::WorkspaceLoader.new(family: @family, today: Date.new(2026, 6, 15)).load
  end

  test "carries plan meta, ordered monthly periods, and the assumption list" do
    island = Forecasts::WorkspaceIsland.from_cache(plan: @loader.plan, cache: @loader.cache).to_h

    assert_equal @loader.plan.id, island[:plan][:id]
    assert_equal @loader.plan.lock_version, island[:plan][:lock_version]
    assert_equal @loader.plan.reporting_currency, island[:plan][:currency]

    periods = island[:periods]
    assert_operator periods.length, :>, 0
    assert_equal periods.map { |p| p[:s] }, periods.map { |p| p[:s] }.sort
    first = periods.first
    %i[nw lc inc sp db pv rd].each { |k| assert first[:m].key?(k), "missing metric #{k}" }

    entries = island[:assumptions]
    @loader.plan.forecast_assumptions.each do |a|
      assert entries.any? { |e| e[:id] == a.id }, "assumption #{a.id} missing from list"
    end
    # per-period active-assumption refs are ordinal indexes into the list, never
    # UUIDs (361 periods x N UUIDs would blow the size budget)
    periods.each do |p|
      p[:aa].each { |ref| assert_includes 0...entries.length, ref }
    end
  end

  test "serializes under the 150KB budget for a representative 30y x 25-assumption plan" do
    plan = @loader.plan
    plan.update!(horizon_end_on: plan.horizon_start_on >> 360)
    13.times do |i|
      plan.forecast_assumptions.create!(
        family: @family, kind: "salary", name: "Income #{i}", status: :active,
        amount: 4000 + i, currency: "USD",
        params: { "frequency" => "monthly", "growth_policy" => "flat" })
    end
    12.times do |i|
      plan.forecast_assumptions.create!(
        family: @family, kind: "living_expense", name: "Expense #{i}", status: :active,
        amount: 900 + i, currency: "USD",
        params: { "frequency" => "monthly", "inflation_policy" => "flat" })
    end
    plan.increment!(:current_plan_version)
    snapshot = Forecasts::SourceSnapshotBuilder.new(plan: plan, as_of: Date.new(2026, 6, 15)).build
    cache = Forecasts::Projection::RecomputeCoordinator
      .new(plan: plan, source_snapshot: snapshot, anchor_on: Date.new(2026, 6, 15))
      .recompute

    json = Forecasts::WorkspaceIsland.from_cache(plan: plan, cache: cache).to_json
    assert_operator json.bytesize, :<, 150_000, "island is #{json.bytesize} bytes (budget 150KB)"
  end

  test "from_result and from_cache serialize byte-identical JSON for the same projection" do
    # Amendment A: the save path renders the island from the in-memory engine
    # Result (compute-synchronous, persist-async), while GETs render it from
    # the persisted cache. The client must not be able to tell them apart.
    plan = @loader.plan
    cache = @loader.cache
    result = Forecasts::Projection::RecomputeCoordinator
      .new(plan: plan, source_snapshot: cache.forecast_source_snapshot, anchor_on: Date.new(2026, 6, 15))
      .compute

    cache_json = Forecasts::WorkspaceIsland.from_cache(plan: plan, cache: cache).to_json
    result_json = Forecasts::WorkspaceIsland.from_result(plan: plan, result: result).to_json

    assert_equal cache_json, result_json
  end
end
