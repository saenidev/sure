# frozen_string_literal: true

require "test_helper"
require Rails.root.join("test/fixtures/files/forecasts/connected_family_proof")

# Forecast V2 BACKEND PROOF SLICE contract test (spec "Backend Proof Slice",
# Acceptance Matrix "Backend proof slice").
#
# This is the backend gate, not a UI milestone. It ties B9-B14 together
# end-to-end for ONE connected-family fixture and proves the modern workspace has
# a fast, explainable substrate that does NOT touch the V1 forecast machinery:
#
#   source snapshot (B9) -> default plan + derived assumptions (B10) ->
#   plan packet (B11) -> pure engine (B4-B7) -> recompute coordinator persists a
#   keyed cache + >=36 indexed period rows + trace rows (B12) ->
#   read models (B13) load the selected period from indexed rows.
#
# Pass criteria asserted here (spec "Backend Proof Slice"):
#   - opening the default-plan path creates exactly one plan + one source
#     snapshot + salary/living_expense assumptions + a baseline projection cache
#     with >=36 period rows and trace rows;
#   - NO V1 records are created or read (no forecast_run_groups / forecast_runs /
#     forecast_days / forecast_months rows; no Forecast::Runner / Workspace /
#     InputBuilder / Engine is invoked — mocha fails if any is);
#   - the engine entrypoint receives only a packet value object and queries no
#     ActiveRecord;
#   - SelectedPeriodReadModel loads the selected month from indexed rows WITHOUT
#     parsing the full projection-result JSON;
#   - a stale recompute cannot overwrite a newer plan version;
#   - missing FX returns a structured issue, not an exception.
class Forecasts::BackendProofSliceTest < ActiveSupport::TestCase
  # V1 output tables the proof slice must never create or read as required state.
  V1_RUN_MODELS = [ ForecastRunGroup, ForecastRun, ForecastDay, ForecastMonth ].freeze

  # V1 service classes the proof slice must never invoke.
  V1_SERVICE_CLASSES = [
    Forecast::Runner,
    Forecast::Workspace,
    Forecast::InputBuilder,
    Forecast::Engine
  ].freeze

  setup do
    @scenario = Forecasts::ConnectedFamilyProof.build(
      family: families(:dylan_family),
      depository_account: accounts(:depository),
      budget: budgets(:one),
      as_of: Date.new(2026, 6, 1)
    )
    @family = @scenario.family
    @as_of = @scenario.as_of
  end

  # --- The whole backend gate, in order -----------------------------------

  # Opening the default-plan path for the connected family must build exactly the
  # documented record set in one pass: one plan, one source snapshot, the two
  # typed assumptions, one baseline cache, >=36 period rows, and trace rows.
  test "opening the default-plan path builds the documented backend record set" do
    plan = source_snapshot = cache = nil

    assert_difference -> { Forecasts::Plan.where(family: @family).count } => 1,
                      -> { Forecasts::SourceSnapshot.where(family: @family).count } => 1,
                      -> { Forecasts::Assumption.where(family: @family).count } => 2,
                      -> { Forecasts::ProjectionCache.count } => 1 do
      plan = build_default_plan
      source_snapshot = build_snapshot(plan)
      cache = recompute(plan, source_snapshot)
    end

    # Exactly one active plan in the family's reporting currency.
    assert plan.persisted?
    assert plan.active?
    assert_equal @family.id, plan.family_id

    # The two typed assumptions, both source-derived with provenance.
    kinds = plan.forecast_assumptions.pluck(:kind).sort
    assert_equal %w[living_expense salary], kinds
    plan.forecast_assumptions.each do |assumption|
      assert_equal "source_derived", assumption.origin
      assert_equal "needs_review", assumption.review_state
    end

    # The salary derives from the payroll source record; living from the budget.
    salary = plan.forecast_assumptions.find_by(kind: "salary")
    living = plan.forecast_assumptions.find_by(kind: "living_expense")
    assert_equal @scenario.payroll.id, salary.source_record_id
    assert_equal Forecasts::ConnectedFamilyProof::DERIVED_SALARY_AMOUNT, salary.amount
    assert_equal @scenario.budget.id, living.source_record_id
    assert_equal Forecasts::ConnectedFamilyProof::DERIVED_LIVING_AMOUNT, living.amount

    # One source snapshot scoped to the plan/family with a stable hash.
    assert_equal plan.id, source_snapshot.forecast_plan_id
    assert_equal @family.id, source_snapshot.family_id
    assert source_snapshot.source_snapshot_hash.present?

    # One baseline projection cache, fresh, keyed and hashed.
    assert cache.fresh?
    assert_equal "baseline", cache.scenario_stack_key
    assert_equal plan.current_plan_version, cache.plan_version
    assert_equal Forecasts::Projection::PacketBuilder::ENGINE_VERSION, cache.engine_version
    assert cache.projection_result_hash.present?

    # >=36 indexed period rows and trace rows for the salary + living flows.
    assert_operator cache.forecast_projection_periods.count, :>=, 36,
      "the baseline projection cache must index at least 36 period rows"
    assert_operator cache.forecast_projection_traces.count, :>, 0,
      "the baseline projection cache must index trace rows for the flows"
  end

  # --- No V1 records created or read --------------------------------------

  test "the full pipeline creates no V1 run-group/run/day/month rows" do
    before_counts = V1_RUN_MODELS.to_h { |model| [ model, model.count ] }

    plan = build_default_plan
    source_snapshot = build_snapshot(plan)
    recompute(plan, source_snapshot)
    open_selected_period_read_model(plan)

    V1_RUN_MODELS.each do |model|
      assert_equal before_counts[model], model.count,
        "#{model} rows must not change; the V2 proof slice must not touch V1 run output"
    end
  end

  test "the full pipeline never invokes any V1 forecast service" do
    # Every V1 service is constructed (`.new`) and driven through its instance
    # `#call`. mocha fails the test if either entrypoint fires during the
    # pipeline, so the V2 path cannot secretly delegate to V1.
    V1_SERVICE_CLASSES.each do |klass|
      klass.expects(:new).never
      klass.any_instance.expects(:call).never
    end

    plan = build_default_plan
    source_snapshot = build_snapshot(plan)
    recompute(plan, source_snapshot)
    open_selected_period_read_model(plan)
  end

  # --- Engine purity: packet-only, no ActiveRecord ------------------------

  test "the engine entrypoint receives only a packet value object" do
    plan = build_default_plan
    source_snapshot = build_snapshot(plan)

    captured = nil
    real_engine = Forecasts::Projection::Engine.method(:call)
    Forecasts::Projection::Engine.stubs(:call).with do |arg|
      captured = arg
      true
    end.returns(real_engine.call(
      Forecasts::Projection::PacketBuilder.new(plan: plan, source_snapshot: source_snapshot).build
    ))

    recompute(plan, source_snapshot)

    assert_kind_of Forecasts::Projection::Packet, captured,
      "Engine.call must receive a Forecasts::Projection::Packet, never a model/relation/params"
    refute captured.is_a?(ActiveRecord::Base)
    refute captured.respond_to?(:to_sql), "the packet must not be an ActiveRecord relation"
  end

  test "the engine queries no ActiveRecord while projecting from the packet" do
    plan = build_default_plan
    source_snapshot = build_snapshot(plan)
    packet = Forecasts::Projection::PacketBuilder.new(
      plan: plan, source_snapshot: source_snapshot
    ).build

    assert_queries_count(max: 0) do
      Forecasts::Projection::Engine.call(packet)
    end
  end

  test "the engine rejects an ActiveRecord-shaped input instead of querying it" do
    plan = build_default_plan

    assert_raises(Forecasts::Projection::Engine::InvalidInputError) do
      Forecasts::Projection::Engine.call(plan)
    end
  end

  # --- SelectedPeriodReadModel loads indexed rows, not full JSON ----------

  test "SelectedPeriodReadModel loads the selected month from indexed rows" do
    plan = build_default_plan
    source_snapshot = build_snapshot(plan)
    cache = recompute(plan, source_snapshot)

    period = cache.forecast_projection_periods.ordered.first
    traces = cache.forecast_projection_traces.for_period(period.period_key).ordered.to_a

    payload = nil
    # Period + traces are already loaded; shaping the read model must issue NO
    # additional query (no per-trace, per-issue, or full-JSON read).
    assert_queries_count(max: 0) do
      payload = Forecasts::SelectedPeriodReadModel.new(
        period: period, traces: traces, cache: cache
      ).to_h
    end

    assert_equal period.period_key, payload[:period_key]
    refute_empty payload[:metrics]
    refute_empty payload[:explanation]
    assert_equal traces.length, payload[:explanation].length
  end

  test "no full projection-result JSON exists to parse for selected-period reads" do
    plan = build_default_plan
    source_snapshot = build_snapshot(plan)
    cache = recompute(plan, source_snapshot)

    # The cache stores only a result HASH, never a full result body. This guards
    # the contract by shape: there is no column the read model could parse.
    refute cache.respond_to?(:projection_result),
      "the cache must not expose a full projection-result JSON body"
    refute cache.attributes.key?("projection_result"),
      "no full projection-result JSON column may exist; reads use indexed rows"
    assert cache.attributes.key?("projection_result_hash"),
      "the cache keys/coalesces on a result hash, not a full-JSON body"
  end

  # --- Stale-result protection --------------------------------------------

  test "a stale recompute cannot overwrite a newer plan version" do
    plan = build_default_plan
    source_snapshot = build_snapshot(plan)

    fresh = recompute(plan, source_snapshot)
    fresh_version = fresh.plan_version

    # The plan advances past the version this work was scheduled for (an edit
    # committed elsewhere) before the stale recompute publishes.
    stale_coordinator = Forecasts::Projection::RecomputeCoordinator.new(
      plan: plan, source_snapshot: source_snapshot
    )
    plan.update!(current_plan_version: fresh_version + 3)

    result = nil
    assert_no_difference -> { Forecasts::ProjectionCache.current.count } do
      result = stale_coordinator.recompute(against_plan_version: fresh_version)
    end

    # The live cache stays fresh and untouched; the stale work published nothing.
    assert fresh.reload.fresh?, "the prior cache must remain the live, fresh result"
    live = Forecasts::ProjectionCache.current.where(
      status: "fresh", forecast_plan_id: plan.id, scenario_stack_key: "baseline"
    )
    assert_equal [ fresh.id ], live.pluck(:id),
      "a stale-version recompute must not publish over the live cache"
    assert result.nil? || result.superseded?,
      "a stale recompute returns nothing publishable or a superseded marker"
  end

  # --- Missing FX returns a structured issue ------------------------------

  test "missing FX surfaces as a structured snapshot issue candidate, not an exception" do
    Forecasts::ConnectedFamilyProof.add_unconvertible_foreign_account(family: @family)

    plan = build_default_plan
    source_snapshot = nil
    assert_nothing_raised do
      source_snapshot = build_snapshot(plan)
    end

    codes = source_snapshot.issue_candidates.map { |candidate| candidate.deep_symbolize_keys[:code] }
    assert_includes codes, "missing_fx_rate",
      "a foreign account with no usable rate must produce a structured missing_fx_rate candidate"

    missing = source_snapshot.issue_candidates
      .map(&:deep_symbolize_keys)
      .find { |candidate| candidate[:code] == "missing_fx_rate" }
    assert_equal "JPY", missing[:currency]
    assert_equal "error", missing[:severity]
    assert missing[:message_key].present?, "the issue must carry an i18n message key"
  end

  test "missing FX inside the engine yields a structured issue, never a raised error" do
    Forecasts::ConnectedFamilyProof.add_unconvertible_foreign_account(family: @family)

    # A salary in the unconvertible currency forces the engine onto the missing-FX
    # path during simulation; it must record a structured issue, not raise.
    plan = build_default_plan
    plan.forecast_assumptions.create!(
      family: @family,
      kind: "salary",
      name: "Tokyo stipend",
      status: :active,
      amount: 100_000,
      currency: "JPY",
      starts_on: @as_of,
      params: { "frequency" => "monthly" }
    )
    source_snapshot = build_snapshot(plan)
    packet = Forecasts::Projection::PacketBuilder.new(
      plan: plan, source_snapshot: source_snapshot
    ).build

    result = nil
    assert_nothing_raised { result = Forecasts::Projection::Engine.call(packet) }

    assert_includes result.issues.map(&:code), "missing_fx_rate"
    assert_includes Forecasts::Projection::Result::STATUSES, result.status
    refute_equal "clean", result.status,
      "a missing-FX flow must not project as a clean result"
  end

  # A FLOWLESS excluded foreign account (an opening balance the snapshot dropped
  # for want of a usable rate, with NO recurring/assumption flow in that currency)
  # must still surface a missing_fx_rate issue end-to-end: in the engine result
  # AND in the persisted cache issue summary. Without folding snapshot issue
  # candidates into the result, the account silently vanishes from net worth/cash
  # with no issue (breaks "Recover From Missing Data").
  test "a flowless excluded foreign account surfaces missing_fx_rate in result and cache" do
    Forecasts::ConnectedFamilyProof.add_unconvertible_foreign_account(family: @family)

    plan = build_default_plan
    source_snapshot = build_snapshot(plan)
    packet = Forecasts::Projection::PacketBuilder.new(
      plan: plan, source_snapshot: source_snapshot
    ).build

    # There is NO JPY flow (the family has only USD salary + living expense), so
    # the per-period FX path never fires; the issue can only come from the
    # snapshot candidate folded into the result.
    assert(packet.assumptions.none? { |a| a[:params][:currency].to_s == "JPY" },
      "the proof family has no JPY flow; the issue must come from the snapshot, not a flow")

    result = Forecasts::Projection::Engine.call(packet)
    assert_includes result.issues.map(&:code), "missing_fx_rate",
      "a flowless excluded foreign account must still surface a missing_fx_rate result issue"
    refute_equal "clean", result.status, "an excluded account downgrades status from clean"

    cache = recompute(plan, source_snapshot)
    summary = cache.issue_summary
    assert_includes summary["codes"].keys, "missing_fx_rate",
      "the persisted cache issue summary must carry the snapshot-sourced issue"
    assert_operator summary["issue_count"], :>=, 1
  end

  # --- Golden-fixture-style provenance recorded on the cache --------------

  test "the persisted cache records packet/engine/scenario provenance" do
    plan = build_default_plan
    source_snapshot = build_snapshot(plan)
    packet = Forecasts::Projection::PacketBuilder.new(
      plan: plan, source_snapshot: source_snapshot
    ).build

    cache = recompute(plan, source_snapshot)

    assert_equal packet.engine_version, cache.engine_version
    assert_equal packet.scenario_stack_hash, cache.scenario_stack_hash
    assert_equal packet.source_snapshot_hash, cache.source_snapshot_hash
    assert_equal packet.plan[:version], cache.plan_version

    # Selected-period trace IDs are recoverable from the indexed trace rows.
    period = cache.forecast_projection_periods.ordered.first
    traces = cache.forecast_projection_traces.for_period(period.period_key).to_a
    assert traces.any?, "the first period must have indexed trace rows"
    assert traces.all? { |trace| trace.id.present? }
  end

  private
    def build_default_plan
      Forecasts::DefaultPlanBuilder.new(family: @family, as_of: @as_of).build
    end

    def build_snapshot(plan)
      Forecasts::SourceSnapshotBuilder.new(plan: plan, as_of: @as_of).build
    end

    def recompute(plan, source_snapshot)
      Forecasts::Projection::RecomputeCoordinator.new(
        plan: plan, source_snapshot: source_snapshot
      ).recompute
    end

    def open_selected_period_read_model(plan)
      cache = plan.forecast_projection_caches.current.where(status: "fresh").first
      return if cache.nil?

      period = cache.forecast_projection_periods.ordered.first
      traces = cache.forecast_projection_traces.for_period(period.period_key).ordered.to_a
      Forecasts::SelectedPeriodReadModel.new(period: period, traces: traces, cache: cache).to_h
    end

    # Counts SELECT queries issued inside the block (ignoring SCHEMA/transaction
    # control), matching the read-model contract tests' helper.
    def assert_queries_count(max:)
      queries = []
      callback = lambda do |_name, _start, _finish, _id, payload|
        sql = payload[:sql]
        next if sql.nil?
        next if payload[:name].to_s.include?("SCHEMA")
        queries << sql if sql.match?(/SELECT/)
      end
      ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { yield }
      assert queries.size <= max, "expected at most #{max} queries, got #{queries.size}:\n#{queries.join("\n")}"
    end
end
