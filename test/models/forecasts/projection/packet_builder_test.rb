# frozen_string_literal: true

require "test_helper"

# Tests for the Forecast V2 plan packet builder. The builder combines a
# Forecasts::Plan, its enabled baseline assumptions, the baseline scenario
# stack, resolved milestones, and a Forecasts::SourceSnapshot into a
# Forecasts::Projection::Packet value object with version metadata.
#
# It derives family_id server-side from the plan (never from params), is
# deterministic (same plan version + snapshot hash -> same packet hash), and does
# NOT persist or render. See spec "Plan Packet" and the "Plan packet builder"
# boundary ("Combining plan, scenario stack, source snapshot, and version
# metadata into engine input | Persistence or UI rendering").
class Forecasts::Projection::PacketBuilderTest < ActiveSupport::TestCase
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

  def build
    Forecasts::Projection::PacketBuilder.new(plan: @plan, source_snapshot: @snapshot).build
  end

  # --- Packet construction -------------------------------------------------

  test "builds a valid Forecasts::Projection::Packet from a plan + snapshot" do
    add_salary
    add_living_expense

    packet = build

    assert_kind_of Forecasts::Projection::Packet, packet
    assert packet.frozen?
    assert_equal @plan.id, packet.plan.fetch(:id)
    assert_equal "USD", packet.plan.fetch(:reporting_currency)
    assert_equal @as_of.iso8601, packet.plan.dig(:horizon, :starts_on)
    assert_equal (@as_of >> 36).iso8601, packet.plan.dig(:horizon, :ends_on)
  end

  test "the resulting packet is accepted by the pure engine" do
    add_salary
    add_living_expense

    result = Forecasts::Projection::Engine.call(build)

    assert_kind_of Forecasts::Projection::Result, result
    assert_equal 36, result.periods.length
    assert_equal "6000.00", result.periods.first[:metrics][:income]
    assert_equal "4000.00", result.periods.first[:metrics][:spending]
  end

  test "carries the schema and engine version metadata" do
    packet = build

    assert_equal Forecasts::Projection::PacketBuilder::SCHEMA_VERSION, packet.schema_version
    assert_equal Forecasts::Projection::PacketBuilder::ENGINE_VERSION, packet.engine_version
  end

  test "threads the plan version so traces stay stable per revision" do
    @plan.update!(current_plan_version: 9)

    assert_equal 9, build.plan.fetch(:version)
  end

  # --- Family scoping (server-side) ----------------------------------------

  test "derives family_id from the plan record, never from params" do
    packet = build

    assert_equal @family.id, packet.plan.fetch(:family_id)
  end

  test "never trusts a family_id argument: there is no way to inject one" do
    # The builder's only inputs are the plan and the snapshot; family is read off
    # the plan. A different family's plan yields that family's id.
    other_family = families(:empty)
    other_plan = Forecasts::Plan.create!(
      family: other_family,
      name: "Other",
      horizon_start_on: @as_of,
      horizon_end_on: @as_of >> 12,
      reporting_currency: "USD"
    )
    other_snapshot = Forecasts::SourceSnapshotBuilder.new(plan: other_plan, as_of: @as_of).build

    packet = Forecasts::Projection::PacketBuilder.new(plan: other_plan, source_snapshot: other_snapshot).build

    assert_equal other_family.id, packet.plan.fetch(:family_id)
  end

  # --- Baseline assumptions ------------------------------------------------

  test "includes enabled baseline assumptions and excludes disabled/archived" do
    salary = add_salary
    add_living_expense(status: :disabled)
    add_salary(name: "Archived", status: :archived)

    packet = build
    ids = packet.assumptions.map { |a| a[:id] }

    assert_includes ids, salary.id
    assert_equal 1, packet.assumptions.length
  end

  test "maps assumption columns into the engine params shape" do
    salary = add_salary(amount: 7500, currency: "USD", starts_on: @as_of, ends_on: @as_of >> 24)

    assumption = build.assumptions.find { |a| a[:id] == salary.id }

    assert_equal "salary", assumption[:kind]
    assert_equal "active", assumption[:status]
    assert_equal "7500.0", assumption.dig(:params, :amount)
    assert_equal "USD", assumption.dig(:params, :currency)
    assert_equal "monthly", assumption.dig(:params, :frequency)
    # starts_on/ends_on become deterministic date anchors for the expander.
    assert_equal({ type: "date", on: @as_of.iso8601 }, assumption.dig(:params, :start_anchor))
    assert_equal({ type: "date", on: (@as_of >> 24).iso8601 }, assumption.dig(:params, :end_anchor))
  end

  test "preserves stored params (person_key, gross_or_net) on the salary" do
    salary = add_salary

    params = build.assumptions.find { |a| a[:id] == salary.id }[:params]

    assert_equal "primary", params[:person_key]
    assert_equal "net", params[:gross_or_net]
  end

  # --- Milestones ----------------------------------------------------------

  test "resolves milestones into deterministic dates for the engine" do
    milestone = @plan.forecast_milestones.create!(
      name: "Retirement", kind: "retirement", date: @as_of >> 30
    )

    packet = build
    resolved = packet.milestones.find { |m| m[:id] == milestone.id }

    assert resolved.present?, "expected the milestone to be in the packet"
    assert_equal (@as_of >> 30).iso8601, resolved[:resolved_on]
  end

  test "an assumption anchored to a milestone resolves through the packet" do
    milestone = @plan.forecast_milestones.create!(
      name: "Retirement", kind: "retirement", date: @as_of >> 12
    )
    salary = add_salary(
      ends_at_milestone: milestone,
      params: { "person_key" => "primary", "frequency" => "monthly", "gross_or_net" => "net" }
    )

    assumption = build.assumptions.find { |a| a[:id] == salary.id }

    assert_equal({ type: "milestone", milestone_key: milestone.id }, assumption.dig(:params, :end_anchor))

    # And the engine can resolve it: salary stops after the milestone month.
    result = Forecasts::Projection::Engine.call(build)
    income_periods = result.periods.count { |p| p[:metrics][:income] != "0.00" }
    assert income_periods.positive?
    assert income_periods < 36, "salary should stop at the milestone, not run the full horizon"
  end

  # --- Scenario stack ------------------------------------------------------

  test "produces the baseline scenario stack" do
    packet = build

    assert_equal "baseline", packet.scenario_stack.fetch(:key)
    assert_equal [], packet.scenario_stack.fetch(:layer_ids)
    assert_equal [], packet.scenario_operations
  end

  # --- Source snapshot -----------------------------------------------------

  test "embeds the source snapshot payload and matches its hash" do
    packet = build

    assert_equal @snapshot.snapshot_payload.deep_symbolize_keys[:as_of], packet.source_snapshot[:as_of]
    assert_equal @snapshot.source_snapshot_hash, packet.source_snapshot_hash
  end

  # --- Determinism ---------------------------------------------------------

  test "same plan version + snapshot hash yields the same packet hash" do
    add_salary
    add_living_expense

    a = build
    b = build

    assert_equal a.input_packet_hash, b.input_packet_hash
    assert_equal a.source_snapshot_hash, b.source_snapshot_hash
    assert_equal a.scenario_stack_hash, b.scenario_stack_hash
  end

  test "packet hash changes when the plan version changes" do
    add_salary
    before = build.input_packet_hash

    @plan.update!(current_plan_version: 2)
    after = build.input_packet_hash

    refute_equal before, after
  end

  test "packet hash changes when the source snapshot hash changes" do
    add_salary
    before = build.input_packet_hash

    accounts(:depository).update!(balance: 123_456)
    @snapshot = Forecasts::SourceSnapshotBuilder.new(plan: @plan, as_of: @as_of).build
    after = build.input_packet_hash

    refute_equal before, after
  end

  # --- Boundary: no persistence, no rendering ------------------------------

  test "does not persist any records" do
    add_salary

    assert_no_difference [
      -> { Forecasts::SourceSnapshot.count },
      -> { Forecasts::Assumption.count },
      -> { Forecasts::Plan.count }
    ] do
      build
    end
  end
end
