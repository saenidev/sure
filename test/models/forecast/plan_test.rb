# frozen_string_literal: true

require "test_helper"

# Forecast V2 models live under the pluralized `Forecasts::` namespace so the V1
# `Forecast::` service classes (engine/runner/workspace) coexist untouched. This
# test exercises the whole V2 model set (associations, enums, family scoping,
# optimistic locking) per the "Plan repository" and "Family Scoping" boundaries.
class Forecasts::PlanTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @other_family = families(:empty)
  end

  def build_plan(family: @family, **attrs)
    family.forecast_plans.create!(
      {
        name: "Default plan",
        horizon_start_on: Date.new(2026, 6, 1),
        horizon_end_on: Date.new(2029, 6, 1),
        reporting_currency: "USD"
      }.merge(attrs)
    )
  end

  # --- Family scoping -------------------------------------------------------

  test "family has_many forecast_plans" do
    plan = build_plan
    assert_includes @family.forecast_plans, plan
    assert_not_includes @other_family.forecast_plans, plan
  end

  test "plan belongs to family and is scoped to it" do
    plan = build_plan
    assert_equal @family, plan.family
  end

  test "assumptions are reachable through the family scope" do
    plan = build_plan
    assumption = plan.forecast_assumptions.create!(
      family: @family,
      kind: "salary",
      name: "Primary salary"
    )

    assert_includes @family.forecast_assumptions, assumption
    assert_not_includes @other_family.forecast_assumptions, assumption
  end

  test "source snapshots are reachable through the family scope" do
    plan = build_plan
    snapshot = plan.forecast_source_snapshots.create!(
      family: @family,
      source_snapshot_hash: "abc123",
      as_of: Date.new(2026, 6, 1)
    )

    assert_includes @family.forecast_source_snapshots, snapshot
  end

  # --- Plan associations ----------------------------------------------------

  test "plan has_many milestones/assumptions/scenario_layers/source_snapshots/projection_caches" do
    plan = build_plan

    milestone = plan.forecast_milestones.create!(name: "Retirement", kind: "retirement")
    assumption = plan.forecast_assumptions.create!(family: @family, kind: "salary", name: "Salary")
    layer = plan.forecast_scenario_layers.create!(name: "Aggressive")
    snapshot = plan.forecast_source_snapshots.create!(
      family: @family, source_snapshot_hash: "h", as_of: Date.new(2026, 6, 1)
    )
    cache = plan.forecast_projection_caches.create!(
      plan_version: 1,
      scenario_stack_key: "baseline",
      scenario_stack_hash: "shash",
      source_snapshot_hash: "h",
      engine_version: "v1"
    )

    assert_includes plan.forecast_milestones, milestone
    assert_includes plan.forecast_assumptions, assumption
    assert_includes plan.forecast_scenario_layers, layer
    assert_includes plan.forecast_source_snapshots, snapshot
    assert_includes plan.forecast_projection_caches, cache
  end

  test "deleting a plan cascades to children via dependent destroy" do
    plan = build_plan
    plan.forecast_milestones.create!(name: "Retirement", kind: "retirement")
    plan.forecast_assumptions.create!(family: @family, kind: "salary", name: "Salary")

    assert_difference -> { Forecasts::Milestone.count } => -1,
                      -> { Forecasts::Assumption.count } => -1,
                      -> { Forecasts::Plan.count } => -1 do
      plan.destroy
    end
  end

  # --- Cache -> periods/traces ---------------------------------------------

  test "cache has_many periods and traces" do
    plan = build_plan
    cache = plan.forecast_projection_caches.create!(
      plan_version: 1,
      scenario_stack_key: "baseline",
      scenario_stack_hash: "shash",
      source_snapshot_hash: "h",
      engine_version: "v1"
    )

    period = cache.forecast_projection_periods.create!(
      forecast_plan: plan,
      scenario_stack_key: "baseline",
      period_key: "2026-06",
      period_start_on: Date.new(2026, 6, 1),
      period_end_on: Date.new(2026, 6, 30),
      granularity: "month",
      plan_version: 1,
      engine_version: "v1"
    )

    trace = cache.forecast_projection_traces.create!(
      period_key: "2026-06",
      granularity: "month",
      metric_key: "net_worth",
      trace_kind: "assumption_flow"
    )

    assert_includes cache.forecast_projection_periods, period
    assert_includes cache.forecast_projection_traces, trace
  end

  # --- Layer -> layer_assumptions ------------------------------------------

  test "layer has_many layer_assumptions" do
    plan = build_plan
    layer = plan.forecast_scenario_layers.create!(name: "Aggressive")
    assumption = plan.forecast_assumptions.create!(family: @family, kind: "salary", name: "Salary")

    link = layer.forecast_scenario_layer_assumptions.create!(
      forecast_assumption: assumption,
      operation: "override"
    )

    assert_includes layer.forecast_scenario_layer_assumptions, link
    assert_includes layer.forecast_assumptions, assumption
  end

  # --- Enums ----------------------------------------------------------------

  test "plan status enum" do
    plan = build_plan
    assert plan.active?
    plan.archived!
    assert plan.archived?
    assert_equal %w[active archived], Forecasts::Plan.statuses.keys
  end

  test "assumption enums for status/origin/confidence/review_state" do
    plan = build_plan
    assumption = plan.forecast_assumptions.create!(family: @family, kind: "salary", name: "Salary")

    assert assumption.active?
    assert_equal "user_created", assumption.origin
    assert_equal "confirmed", assumption.review_state

    assert_equal %w[active draft disabled archived], Forecasts::Assumption.statuses.keys
    assert_equal %w[user_created source_derived system_default sample], Forecasts::Assumption.origins.keys
    assert_equal %w[high medium low], Forecasts::Assumption.confidences.keys
    assert_equal %w[confirmed needs_review rejected superseded], Forecasts::Assumption.review_states.keys
  end

  test "scenario layer status enum" do
    plan = build_plan
    layer = plan.forecast_scenario_layers.create!(name: "Aggressive")
    assert layer.active?
    assert_equal %w[active disabled archived], Forecasts::ScenarioLayer.statuses.keys
  end

  test "projection cache status enum" do
    plan = build_plan
    cache = plan.forecast_projection_caches.create!(
      plan_version: 1,
      scenario_stack_key: "baseline",
      scenario_stack_hash: "shash",
      source_snapshot_hash: "h",
      engine_version: "v1"
    )
    assert cache.recomputing?
    assert_equal %w[fresh stale recomputing failed superseded], Forecasts::ProjectionCache.statuses.keys
  end

  test "projection period and trace granularity enum" do
    plan = build_plan
    cache = plan.forecast_projection_caches.create!(
      plan_version: 1,
      scenario_stack_key: "baseline",
      scenario_stack_hash: "shash",
      source_snapshot_hash: "h",
      engine_version: "v1"
    )
    period = cache.forecast_projection_periods.create!(
      forecast_plan: plan,
      scenario_stack_key: "baseline",
      period_key: "2026",
      period_start_on: Date.new(2026, 1, 1),
      period_end_on: Date.new(2026, 12, 31),
      granularity: "year",
      plan_version: 1,
      engine_version: "v1"
    )
    assert period.year?
    assert_equal %w[day month year], Forecasts::ProjectionPeriod.granularities.keys
  end

  test "milestone kind enum" do
    plan = build_plan
    milestone = plan.forecast_milestones.create!(name: "Retire", kind: "retirement")
    assert milestone.retirement?
    assert_includes Forecasts::Milestone.kinds.keys, "custom"
  end

  # --- Optimistic locking ---------------------------------------------------

  test "plan uses optimistic locking via lock_version" do
    plan = build_plan
    stale = Forecasts::Plan.find(plan.id)

    plan.update!(name: "Renamed")

    assert_raises(ActiveRecord::StaleObjectError) do
      stale.update!(name: "Conflicting rename")
    end
  end

  test "assumption uses optimistic locking via lock_version" do
    plan = build_plan
    assumption = plan.forecast_assumptions.create!(family: @family, kind: "salary", name: "Salary")
    stale = Forecasts::Assumption.find(assumption.id)

    assumption.update!(name: "New salary name")

    assert_raises(ActiveRecord::StaleObjectError) do
      stale.update!(name: "Conflicting name")
    end
  end

  # --- Scopes ---------------------------------------------------------------

  test "plan active scope returns only active plans" do
    active = build_plan
    archived = build_plan(status: "archived")

    assert_includes Forecasts::Plan.active, active
    assert_not_includes Forecasts::Plan.active, archived
  end
end
