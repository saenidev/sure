# frozen_string_literal: true

require "test_helper"

# End-to-end tests for the pure projection engine entrypoint. The engine wires
# the full pipeline (validate packet -> assumption expansion -> flow ledger ->
# period simulation -> goal eval stub -> trace builder -> result envelope) and
# returns a single versioned `Forecasts::Projection::Result`. It is pure: no
# ActiveRecord, no jobs, no providers, no UI string formatting, deterministic for
# the same packet. See spec "Engine Contract Envelope", "Trace Builder",
# "Pipeline".
class Forecasts::Projection::EngineTest < ActiveSupport::TestCase
  HORIZON_START = "2026-01-01"
  HORIZON_END = "2029-01-01" # 36-month span, inclusive of the horizon-end month (37 periods)

  def salary_assumption(overrides = {})
    {
      id: "assumption-salary-1",
      kind: "salary",
      status: "active",
      scenario_layer_id: nil,
      params: {
        person_key: "primary",
        amount: "6000.00",
        gross_or_net: "net",
        currency: "USD",
        frequency: "monthly",
        growth_policy: { type: "none" },
        start_anchor: { type: "date", on: HORIZON_START },
        end_anchor: nil
      }
    }.merge(overrides)
  end

  def living_expense_assumption(overrides = {})
    {
      id: "assumption-expense-1",
      kind: "living_expense",
      status: "active",
      scenario_layer_id: nil,
      params: {
        amount: "4000.00",
        currency: "USD",
        frequency: "monthly",
        category_ids: %w[cat-groceries cat-rent],
        inflation_policy: { type: "none" },
        actualization_policy: { type: "none" },
        start_anchor: { type: "date", on: HORIZON_START },
        end_anchor: nil
      }
    }.merge(overrides)
  end

  def packet_attributes(assumptions: nil, overrides: {})
    {
      schema_version: 1,
      engine_version: "forecast_v2.1",
      plan: {
        id: "plan-1",
        family_id: "family-1",
        version: 7,
        reporting_currency: "USD",
        horizon: {
          starts_on: HORIZON_START,
          ends_on: HORIZON_END,
          near_term_daily_days: 90
        }
      },
      scenario_stack: { key: "baseline", layer_ids: [] },
      milestones: [],
      assumptions: assumptions || [ salary_assumption, living_expense_assumption ],
      scenario_operations: [],
      source_snapshot: {
        as_of: "2026-01-01T00:00:00Z",
        reporting_currency: "USD",
        opening_balances: { liquid_cash: "10000.00", debt_balance: "0.00", portfolio_value: "0.00" },
        accounts: [],
        transactions: [],
        recurring_patterns: [],
        debts: [],
        holdings: [],
        prices: [],
        fx_rates: []
      },
      issue_policy: { missing_fx: "issue_limited", missing_price: "issue_limited", invalid_assumption: "block_recompute" }
    }.merge(overrides)
  end

  def build_packet(**kwargs)
    Forecasts::Projection::Packet.new(packet_attributes(**kwargs))
  end

  def call(**kwargs)
    Forecasts::Projection::Engine.call(build_packet(**kwargs))
  end

  # --- Envelope shape ------------------------------------------------------

  test "call returns a Result value object" do
    result = call

    assert_kind_of Forecasts::Projection::Result, result
    assert result.frozen?
  end

  test "result envelope carries all required keys" do
    result = call.to_h

    %i[schema_version engine_version input_packet_hash source_snapshot_hash
       scenario_stack_hash plan_version status periods series traces issues
       goals summary].each do |key|
      assert result.key?(key), "result envelope missing #{key}"
    end
  end

  test "result echoes schema and engine versions from the packet" do
    result = call

    assert_equal 1, result.schema_version
    assert_equal "forecast_v2.1", result.engine_version
  end

  test "result plan_version comes from the packet plan" do
    assert_equal 7, call.plan_version
  end

  # --- Hashes --------------------------------------------------------------

  test "result hashes match the packet hashes" do
    packet = build_packet
    result = Forecasts::Projection::Engine.call(packet)

    assert_equal packet.input_packet_hash, result.input_packet_hash
    assert_equal packet.source_snapshot_hash, result.source_snapshot_hash
    assert_equal packet.scenario_stack_hash, result.scenario_stack_hash
  end

  test "engine is deterministic for the same packet" do
    a = call.to_h
    b = call.to_h

    assert_equal a, b
  end

  # --- Periods + simulation ------------------------------------------------

  test "produces a monthly period series through the horizon-end month" do
    result = call

    # 2026-01..2029-01 is a 36-month span but inclusive of the horizon-end
    # month, so 37 monthly periods are simulated (spec "Period Boundaries").
    assert_equal 37, result.periods.length
    assert_equal "2026-01", result.periods.first[:key]
    assert_equal "2029-01", result.periods.last[:key]
  end

  test "period metrics reflect salary income and living expense spending" do
    jan = call.periods.first

    assert_equal "6000.00", jan[:metrics][:income]
    assert_equal "4000.00", jan[:metrics][:spending]
    assert_equal "12000.00", jan[:metrics][:liquid_cash]
  end

  test "status is clean for a plan without issues" do
    result = call

    assert_equal "clean", result.status
    assert_empty result.issues
  end

  # --- Traces --------------------------------------------------------------

  test "builds one trace per flow with required trace fields" do
    result = call

    # 37 salary + 37 living expense occurrences (monthly across the inclusive
    # 2026-01..2029-01 horizon).
    assert_equal 74, result.traces.length

    trace = result.traces.first
    assert_kind_of Forecasts::Projection::Trace, trace
    %i[id period_key category amount currency direction].each do |field|
      refute_nil trace.public_send(field), "trace missing #{field}"
    end
  end

  test "traces cover income and spending categories" do
    categories = call.traces.map(&:category).uniq.sort

    assert_equal %w[income spending], categories
  end

  test "trace amounts are decimal strings, never floats" do
    call.traces.each do |trace|
      assert_kind_of String, trace.amount
      assert_match(/\A-?\d+\.\d{2}\z/, trace.amount)
    end
  end

  test "trace ids are stable across repeated calls" do
    first = call.traces.map(&:id)
    second = call.traces.map(&:id)

    assert_equal first, second
  end

  test "trace ids change when the plan version changes" do
    base_ids = call.traces.map(&:id).to_set

    other = Forecasts::Projection::Engine.call(
      Forecasts::Projection::Packet.new(
        packet_attributes(overrides: {
          plan: {
            id: "plan-1", family_id: "family-1", version: 99,
            reporting_currency: "USD",
            horizon: { starts_on: HORIZON_START, ends_on: HORIZON_END, near_term_daily_days: 90 }
          }
        })
      )
    )

    assert_empty(other.traces.map(&:id).to_set & base_ids)
  end

  test "each trace links to its assumption and a flow" do
    salary_trace = call.traces.find { |t| t.category == "income" }

    assert_equal "assumption-salary-1", salary_trace.assumption_id
    refute_nil salary_trace.flow_id
    assert_equal "assumption", salary_trace.source_type
  end

  test "period rows reference their trace ids" do
    result = call
    jan = result.periods.first

    refute_empty jan[:trace_ids]
    jan_trace_ids = result.traces.select { |t| t.period_key == "2026-01" }.map(&:id)
    assert_equal jan_trace_ids.sort, jan[:trace_ids].sort
  end

  # --- Goal eval stub ------------------------------------------------------

  test "goals are an empty passthrough for the proof slice" do
    assert_equal [], call.goals
  end

  # --- Empty plan ----------------------------------------------------------

  test "an empty assumption set still produces a valid clean envelope" do
    result = call(assumptions: [])

    assert_equal "clean", result.status
    assert_equal 37, result.periods.length
    assert_empty result.traces
  end

  # --- Disabled assumptions ------------------------------------------------

  test "disabled assumptions produce no flows or traces" do
    result = call(assumptions: [ salary_assumption(status: "disabled"), living_expense_assumption ])

    categories = result.traces.map(&:category).uniq
    assert_equal %w[spending], categories
  end

  # --- Unknown assumption kind (registry guard) ----------------------------

  def unknown_kind_assumption(overrides = {})
    {
      id: "assumption-unknown-1",
      kind: "totally_unknown_kind",
      status: "active",
      scenario_layer_id: nil,
      params: { amount: "100.00", currency: "USD" }
    }.merge(overrides)
  end

  test "an unknown stored kind becomes a blocking plan issue and is not expanded" do
    result = call(assumptions: [ unknown_kind_assumption, living_expense_assumption ])

    issue = result.issues.find { |i| i.code == "unknown_assumption_kind" }
    refute_nil issue, "expected an unknown_assumption_kind issue"
    assert_equal "blocking", issue.severity
    assert_equal "plan_validation", issue.source
    assert_equal "assumption", issue.affected_entity_type
    assert_equal "assumption-unknown-1", issue.affected_entity_id
    assert_equal "blocked", result.status

    # The unknown kind contributes no flows; only the living expense expands.
    assert_equal %w[spending], result.traces.map(&:category).uniq
  end

  test "a disabled unknown kind produces no issue and no flows" do
    result = call(assumptions: [ unknown_kind_assumption(status: "disabled"), living_expense_assumption ])

    assert_empty result.issues.select { |i| i.code == "unknown_assumption_kind" }
    assert_equal %w[spending], result.traces.map(&:category).uniq
  end

  # --- Issues passthrough --------------------------------------------------

  test "missing FX rate surfaces a structured issue and issue_limited status" do
    foreign_salary = salary_assumption(
      id: "assumption-salary-eur",
      params: salary_assumption[:params].merge(currency: "EUR")
    )

    result = call(assumptions: [ foreign_salary, living_expense_assumption ])

    assert_equal "issue_limited", result.status
    assert_includes result.issues.map(&:code), "missing_fx_rate"
  end

  # --- Purity: rejects ActiveRecord-shaped input ---------------------------

  test "rejects an ActiveRecord-shaped input" do
    family = Family.first || families(:dylan_family)

    assert_raises(Forecasts::Projection::Engine::InvalidInputError) do
      Forecasts::Projection::Engine.call(family)
    end
  end

  test "rejects an ActiveRecord relation" do
    assert_raises(Forecasts::Projection::Engine::InvalidInputError) do
      Forecasts::Projection::Engine.call(Family.all)
    end
  end

  test "rejects nil input" do
    assert_raises(Forecasts::Projection::Engine::InvalidInputError) do
      Forecasts::Projection::Engine.call(nil)
    end
  end

  test "accepts a raw packet hash and wraps it" do
    result = Forecasts::Projection::Engine.call(packet_attributes)

    assert_kind_of Forecasts::Projection::Result, result
    assert_equal 37, result.periods.length
  end

  test "an invalid packet hash raises the packet validation error" do
    bad = packet_attributes(overrides: { engine_version: "" })

    assert_raises(Forecasts::Projection::Packet::InvalidPacketError) do
      Forecasts::Projection::Engine.call(bad)
    end
  end
end
