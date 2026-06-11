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

  test "from_cache raises ArgumentError on a nil cache" do
    error = assert_raises(ArgumentError) do
      Forecasts::WorkspaceIsland.from_cache(plan: @loader.plan, cache: nil)
    end
    assert_match(/cache/, error.message)
  end

  test "embeds the packet-lite with re-anchored horizon, opening balances, and pv gates" do
    plan = @loader.plan
    usd = plan.forecast_assumptions.create!(
      family: @family, kind: "salary", name: "USD salary", status: :active,
      amount: 5000, currency: "USD",
      params: { "frequency" => "monthly", "growth_policy" => "flat" })
    eur = plan.forecast_assumptions.create!(
      family: @family, kind: "salary", name: "EUR contract", status: :active,
      amount: 3000, currency: "EUR",
      params: { "frequency" => "monthly", "growth_policy" => "flat" })

    island = Forecasts::WorkspaceIsland.from_cache(plan: plan, cache: @loader.cache).to_h
    packet = island[:packet]

    assert packet, "island must carry the packet-lite when the cache has a snapshot"
    assert_equal plan.reporting_currency, packet[:currency]
    # The packet horizon reproduces the projection's EFFECTIVE horizon. The
    # loader plan starts mid-month (horizon_start_on = the bootstrap day), so
    # rendered periods begin at the beginning of the month while the packet
    # keeps the exact mid-month start — the JS engine needs the true effective
    # start (its occurrence-window clamp uses it), and its monthly walk still
    # lands on the same period keys as the island periods.
    assert_equal plan.horizon_start_on.iso8601, packet.dig(:horizon, :starts_on)
    assert_equal island[:periods].first[:s].to_s[0, 7], packet.dig(:horizon, :starts_on)[0, 7]
    assert_equal plan.horizon_end_on.iso8601, packet.dig(:horizon, :ends_on)
    %i[lc db pv].each { |k| assert packet[:opening].key?(k), "missing opening #{k}" }

    by_id = packet[:assumptions].index_by { |a| a[:id] }
    assert_equal true, by_id.fetch(usd.id)[:pv],
      "USD card of a previewable kind must preview"
    assert_equal false, by_id.fetch(eur.id)[:pv],
      "the JS engine does no FX — a non-plan-currency card must not preview"
    # Params are the ENGINE shape (PacketBuilder output), not the form shape:
    # decimal-string amount, typed policy hash.
    assert_equal "5000.0", by_id.fetch(usd.id).dig(:params, :amount)
    assert_equal "none", by_id.fetch(usd.id).dig(:params, :growth_policy, :type)
  end

  test "labels carry the workspace metric and inspector strings for the client" do
    island = Forecasts::WorkspaceIsland.from_cache(plan: @loader.plan, cache: @loader.cache).to_h

    assert_equal I18n.t("forecasts.workspace.metrics"), island[:labels][:metrics]
    assert_equal I18n.t("forecasts.workspace.inspector"), island[:labels][:inspector]
    # Spot-check real content so a missing-translation marker can't satisfy the
    # equalities above.
    assert_equal "Net worth", island.dig(:labels, :metrics, :net_worth)
    assert_equal "%{count} active assumptions",
      island.dig(:labels, :inspector, :active_assumptions, :other)
  end

  test "packet is nil (preview off) when no snapshot is available" do
    result = Forecasts::Projection::RecomputeCoordinator
      .new(plan: @loader.plan, source_snapshot: @loader.cache.forecast_source_snapshot,
           anchor_on: Date.new(2026, 6, 15))
      .compute

    island = Forecasts::WorkspaceIsland
      .from_result(plan: @loader.plan, result: result, snapshot: nil)
      .to_h

    assert_nil island[:packet]
    assert_operator island[:periods].length, :>, 0,
      "island must keep rendering (preview off) without a snapshot"
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
    result_json = Forecasts::WorkspaceIsland.from_result(
      plan: plan, result: result, snapshot: cache.forecast_source_snapshot
    ).to_json

    assert_equal cache_json, result_json
  end
end
