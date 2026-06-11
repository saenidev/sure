# frozen_string_literal: true

require "test_helper"

# Tests for the Forecast V2 recompute coordinator. Given a plan + source
# snapshot, it builds the engine packet (B11), calls the pure engine (B7), and
# persists a Forecasts::ProjectionCache + indexed ProjectionPeriod rows +
# ProjectionTrace rows in ONE transaction, keyed by plan_version +
# scenario_stack_hash + source_snapshot_hash + engine_version.
#
# Critical behaviors (spec "Recompute coordinator", "Recompute Job Contract",
# "Versioning rules"):
#   - writes exactly one fresh current cache + 37 period rows + trace rows
#     (37 = 36-month span inclusive of the horizon-end month; spec "Period
#     Boundaries")
#   - coalesces duplicate keys (idempotent by key)
#   - marks superseded older caches for the same plan + scenario stack
#   - a STALE result (older plan_version than the plan's current_plan_version)
#     CANNOT publish over a newer cache; it writes nothing current and records a
#     superseded/ignored result.
class Forecasts::Projection::RecomputeCoordinatorTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @as_of = Date.new(2026, 6, 1)
    @plan = Forecasts::Plan.create!(
      family: @family,
      name: "Baseline",
      horizon_start_on: @as_of,
      horizon_end_on: @as_of >> 36,
      reporting_currency: "USD"
    )
    add_salary
    add_living_expense
    @snapshot = Forecasts::SourceSnapshotBuilder.new(plan: @plan, as_of: @as_of).build
  end

  def add_salary(overrides = {})
    @plan.forecast_assumptions.create!({
      family: @family,
      kind: "salary",
      name: "Primary salary",
      status: :active,
      amount: 6000,
      currency: "USD",
      starts_on: @as_of,
      params: { "person_key" => "primary", "frequency" => "monthly", "gross_or_net" => "net" }
    }.merge(overrides))
  end

  def add_living_expense(overrides = {})
    @plan.forecast_assumptions.create!({
      family: @family,
      kind: "living_expense",
      name: "Living expenses",
      status: :active,
      amount: 4000,
      currency: "USD",
      starts_on: @as_of,
      params: { "frequency" => "monthly", "basis" => "budget" }
    }.merge(overrides))
  end

  def recompute(plan: @plan, snapshot: @snapshot)
    Forecasts::Projection::RecomputeCoordinator.new(
      plan: plan,
      source_snapshot: snapshot
    ).recompute
  end

  # --- Fresh write ---------------------------------------------------------

  test "writes one fresh cache + 37 period rows + trace rows" do
    cache = nil

    assert_difference -> { Forecasts::ProjectionCache.count } => 1,
                      -> { Forecasts::ProjectionPeriod.count } => 37 do
      cache = recompute
    end

    assert_kind_of Forecasts::ProjectionCache, cache
    assert cache.fresh?
    assert_equal @plan.id, cache.forecast_plan_id
    assert_equal @snapshot.id, cache.forecast_source_snapshot_id
    assert_equal @plan.current_plan_version, cache.plan_version
    assert_equal "baseline", cache.scenario_stack_key
    assert_equal Forecasts::Projection::PacketBuilder::ENGINE_VERSION, cache.engine_version
    assert cache.projection_result_hash.present?
    assert cache.started_at.present?
    assert cache.finished_at.present?

    assert_equal 37, cache.forecast_projection_periods.count
    assert cache.forecast_projection_traces.count.positive?,
      "expected trace rows for the salary + living_expense flows"
  end

  test "the keyed cache carries the packet hashes" do
    packet = Forecasts::Projection::PacketBuilder.new(
      plan: @plan, source_snapshot: @snapshot
    ).build

    cache = recompute

    assert_equal packet.scenario_stack_hash, cache.scenario_stack_hash
    assert_equal packet.source_snapshot_hash, cache.source_snapshot_hash
  end

  test "period rows are indexed for the read paths" do
    cache = recompute
    periods = cache.forecast_projection_periods.ordered.to_a

    assert_equal 37, periods.length
    first = periods.first

    assert_equal @plan.id, first.forecast_plan_id
    assert_equal "baseline", first.scenario_stack_key
    assert first.month?
    assert_equal @plan.current_plan_version, first.plan_version
    assert_equal Forecasts::Projection::PacketBuilder::ENGINE_VERSION, first.engine_version
    assert_equal "6000.00", first.metrics["income"]
    assert_equal "4000.00", first.metrics["spending"]
    assert first.period_key.present?
    assert first.period_start_on.present?
    assert first.period_end_on.present?
  end

  test "trace rows reference the cache, period, and assumption" do
    cache = recompute
    trace = cache.forecast_projection_traces.first

    assert_equal cache.id, trace.forecast_projection_cache_id
    assert trace.period_key.present?
    assert trace.month?
    assert trace.metric_key.present?
    assert trace.trace_kind.present?
    assert trace.assumption_id.present?
  end

  # --- Stale-result protection (CRITICAL) ----------------------------------

  test "a stale plan-version recompute does not overwrite a newer cache" do
    # First, a fresh recompute at the current version produces the live cache.
    fresh = recompute
    fresh_version = fresh.plan_version

    # Build a packet at the OLD version, then the plan moves to a NEWER version
    # (an edit committed elsewhere) before this stale recompute publishes.
    stale_builder = Forecasts::Projection::RecomputeCoordinator.new(
      plan: @plan, source_snapshot: @snapshot
    )

    @plan.update!(current_plan_version: fresh_version + 5)

    # The stale recompute was computed against fresh_version; the plan is now
    # newer. It must NOT overwrite the live cache and must NOT create a fresh
    # current cache for the stale version.
    result = nil
    assert_no_difference -> { Forecasts::ProjectionCache.current.count } do
      result = stale_builder.recompute(against_plan_version: fresh_version)
    end

    # The live cache for the current scenario stack is untouched and still fresh.
    fresh.reload
    assert fresh.fresh?, "the prior cache must remain the live, fresh result"

    # The only fresh current cache for the baseline stack is still the original;
    # the stale recompute published nothing fresh.
    live = Forecasts::ProjectionCache.current
      .where(status: "fresh", forecast_plan_id: @plan.id, scenario_stack_key: "baseline")
    assert_equal [ fresh.id ], live.pluck(:id),
      "no stale-version fresh cache should publish over the live one"

    assert result.nil? || result.superseded?,
      "a stale recompute returns nothing publishable or a superseded marker"
  end

  test "a newer plan-version recompute supersedes the older current cache" do
    older = recompute
    assert older.fresh?

    # The plan advances and its packet changes (new version -> new key).
    @plan.update!(current_plan_version: @plan.current_plan_version + 1)
    newer = recompute

    assert newer.fresh?
    refute_equal older.id, newer.id

    # The older cache is superseded between publishes and pruned by the newer
    # publish (cache hygiene): the row must not outlive the next publish.
    refute Forecasts::ProjectionCache.exists?(older.id),
      "the older cache must be pruned by the newer publish"
    assert_equal 1, Forecasts::ProjectionCache.current
      .where(status: "fresh", forecast_plan_id: @plan.id, scenario_stack_key: "baseline").count
  end

  test "publishing deletes prior caches for the stack so they cannot accumulate" do
    recompute

    # A version bump + a changed input gives the second publish a different key
    # and result hash, so coalescing cannot apply. (SourceSnapshotBuilder is
    # idempotent by content hash — the snapshot row may be reused; the cache key
    # still differs via plan_version.)
    @plan.increment!(:current_plan_version)
    add_salary(name: "Raise", amount: 1234.56)
    second_snapshot = Forecasts::SourceSnapshotBuilder.new(plan: @plan, as_of: @as_of).build
    recompute(snapshot: second_snapshot)

    assert_equal 1, @plan.forecast_projection_caches.count,
      "only the current cache row may survive a publish"
    assert_equal "fresh", @plan.forecast_projection_caches.first.status
  end

  # --- Idempotency by key --------------------------------------------------

  test "recompute is idempotent by key: same key does not duplicate rows" do
    first = recompute

    assert_no_difference [
      -> { Forecasts::ProjectionCache.count },
      -> { Forecasts::ProjectionPeriod.count },
      -> { Forecasts::ProjectionTrace.count }
    ] do
      second = recompute
      assert_equal first.id, second.id, "same key must coalesce onto the same cache row"
    end

    assert_equal 1, Forecasts::ProjectionCache.where(
      forecast_plan_id: @plan.id,
      plan_version: @plan.current_plan_version,
      scenario_stack_hash: first.scenario_stack_hash,
      source_snapshot_hash: first.source_snapshot_hash,
      engine_version: first.engine_version
    ).count
  end

  test "idempotent recompute keeps exactly one current cache for the key" do
    recompute
    recompute
    recompute

    current = Forecasts::ProjectionCache.current.where(
      forecast_plan_id: @plan.id, scenario_stack_key: "baseline"
    )
    assert_equal 1, current.count
  end

  # --- Transactional integrity ---------------------------------------------

  test "a failed persistence rolls back the whole write" do
    Forecasts::ProjectionPeriod.stubs(:insert_all!).raises(ActiveRecord::RecordInvalid.new(Forecasts::ProjectionPeriod.new))

    assert_no_difference [
      -> { Forecasts::ProjectionCache.count },
      -> { Forecasts::ProjectionPeriod.count },
      -> { Forecasts::ProjectionTrace.count }
    ] do
      assert_raises(StandardError) { recompute }
    end
  end

  # --- Bulk persistence + zero-amount trace policy ---------------------------

  test "persists periods and traces with bulk inserts" do
    inserts = 0
    counter = ->(*, payload) { inserts += 1 if payload[:sql].to_s.start_with?("INSERT") }

    cache = nil
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record") do
      cache = recompute
    end

    assert cache.fresh?
    assert_operator cache.forecast_projection_periods.count, :>, 0
    # one INSERT for the cache + one bulk INSERT for periods + at most one for traces
    assert_operator inserts, :<=, 3, "expected bulk inserts, saw #{inserts} INSERT statements"
  end

  test "does not persist zero-amount traces" do
    # A zero salary makes the engine emit zero-amount flow rows for every month;
    # the persistence policy must filter them all.
    add_salary(name: "Zero salary", amount: 0)
    cache = recompute

    assert_equal 0, cache.forecast_projection_traces.where(amount: 0).count
  end
end
