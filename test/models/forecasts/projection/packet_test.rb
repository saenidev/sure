# frozen_string_literal: true

require "test_helper"

# Covers the pure engine value objects (Packet + Result envelope + PlanIssue +
# Trace). These are POROs with no ActiveRecord, so the tests construct them from
# plain hashes and assert on validation, immutability, money-as-string handling,
# and hash determinism. See spec "Engine Contract Envelope", "Plan Issues",
# "Trace Contract".
class Forecasts::Projection::PacketTest < ActiveSupport::TestCase
  def valid_packet_attributes
    {
      schema_version: 1,
      engine_version: "forecast_v2.1",
      plan: {
        id: "11111111-1111-1111-1111-111111111111",
        family_id: "22222222-2222-2222-2222-222222222222",
        reporting_currency: "USD",
        horizon: {
          starts_on: "2026-06-01",
          ends_on: "2031-06-01",
          near_term_daily_days: 90
        }
      },
      scenario_stack: {
        key: "baseline",
        layer_ids: []
      },
      milestones: [],
      assumptions: [],
      scenario_operations: [],
      source_snapshot: {
        as_of: "2026-06-01T00:00:00Z",
        accounts: [],
        transactions: [],
        recurring_patterns: [],
        debts: [],
        holdings: [],
        prices: [],
        fx_rates: []
      },
      issue_policy: {
        missing_fx: "issue_limited",
        missing_price: "issue_limited",
        invalid_assumption: "block_recompute"
      }
    }
  end

  # --- Packet construction -------------------------------------------------

  test "builds a packet from a valid attribute hash" do
    packet = Forecasts::Projection::Packet.new(valid_packet_attributes)

    assert_equal 1, packet.schema_version
    assert_equal "forecast_v2.1", packet.engine_version
    assert_equal "USD", packet.plan.fetch(:reporting_currency)
    assert_equal "baseline", packet.scenario_stack.fetch(:key)
    assert_equal [], packet.assumptions
    assert_equal "2026-06-01T00:00:00Z", packet.source_snapshot.fetch(:as_of)
  end

  test "accepts string keys and normalizes to a deterministic deep structure" do
    string_keyed = JSON.parse(valid_packet_attributes.to_json)
    packet = Forecasts::Projection::Packet.new(string_keyed)

    assert_equal "USD", packet.plan.fetch(:reporting_currency)
    assert_equal "issue_limited", packet.issue_policy.fetch(:missing_fx)
  end

  test "packet is frozen and immutable" do
    packet = Forecasts::Projection::Packet.new(valid_packet_attributes)

    assert packet.frozen?
    assert packet.plan.frozen?
    assert packet.source_snapshot.frozen?
  end

  # --- Packet validation rejection ----------------------------------------

  test "raises typed validation error when schema_version is missing" do
    attrs = valid_packet_attributes.except(:schema_version)

    error = assert_raises(Forecasts::Projection::Packet::InvalidPacketError) do
      Forecasts::Projection::Packet.new(attrs)
    end
    assert_match(/schema_version/, error.message)
  end

  test "raises typed validation error when engine_version is blank" do
    attrs = valid_packet_attributes.merge(engine_version: "")

    assert_raises(Forecasts::Projection::Packet::InvalidPacketError) do
      Forecasts::Projection::Packet.new(attrs)
    end
  end

  test "raises typed validation error when plan reporting_currency is missing" do
    attrs = valid_packet_attributes
    attrs[:plan] = attrs[:plan].except(:reporting_currency)

    error = assert_raises(Forecasts::Projection::Packet::InvalidPacketError) do
      Forecasts::Projection::Packet.new(attrs)
    end
    assert_match(/reporting_currency/, error.message)
  end

  test "raises typed validation error when horizon dates are missing" do
    attrs = valid_packet_attributes
    attrs[:plan] = attrs[:plan].merge(horizon: { near_term_daily_days: 90 })

    assert_raises(Forecasts::Projection::Packet::InvalidPacketError) do
      Forecasts::Projection::Packet.new(attrs)
    end
  end

  test "raises typed validation error when source_snapshot as_of is missing" do
    attrs = valid_packet_attributes
    attrs[:source_snapshot] = attrs[:source_snapshot].except(:as_of)

    error = assert_raises(Forecasts::Projection::Packet::InvalidPacketError) do
      Forecasts::Projection::Packet.new(attrs)
    end
    assert_match(/as_of/, error.message)
  end

  test "raises typed validation error when scenario_stack key is missing" do
    attrs = valid_packet_attributes
    attrs[:scenario_stack] = { layer_ids: [] }

    assert_raises(Forecasts::Projection::Packet::InvalidPacketError) do
      Forecasts::Projection::Packet.new(attrs)
    end
  end

  test "InvalidPacketError is a kind of ArgumentError" do
    assert Forecasts::Projection::Packet::InvalidPacketError.ancestors.include?(ArgumentError)
  end

  # --- Hash determinism ----------------------------------------------------

  test "input_packet_hash is deterministic for equal inputs" do
    a = Forecasts::Projection::Packet.new(valid_packet_attributes)
    b = Forecasts::Projection::Packet.new(valid_packet_attributes)

    assert_equal a.input_packet_hash, b.input_packet_hash
  end

  test "input_packet_hash ignores key ordering in nested hashes" do
    reordered = valid_packet_attributes
    reordered[:issue_policy] = {
      invalid_assumption: "block_recompute",
      missing_price: "issue_limited",
      missing_fx: "issue_limited"
    }

    a = Forecasts::Projection::Packet.new(valid_packet_attributes)
    b = Forecasts::Projection::Packet.new(reordered)

    assert_equal a.input_packet_hash, b.input_packet_hash
  end

  test "input_packet_hash changes when meaningful content changes" do
    a = Forecasts::Projection::Packet.new(valid_packet_attributes)

    changed = valid_packet_attributes
    changed[:plan] = changed[:plan].merge(reporting_currency: "EUR")
    b = Forecasts::Projection::Packet.new(changed)

    refute_equal a.input_packet_hash, b.input_packet_hash
  end

  test "source_snapshot_hash and scenario_stack_hash are deterministic" do
    a = Forecasts::Projection::Packet.new(valid_packet_attributes)
    b = Forecasts::Projection::Packet.new(valid_packet_attributes)

    assert_equal a.source_snapshot_hash, b.source_snapshot_hash
    assert_equal a.scenario_stack_hash, b.scenario_stack_hash
  end

  test "scenario_stack_hash changes when layer_ids change" do
    a = Forecasts::Projection::Packet.new(valid_packet_attributes)

    changed = valid_packet_attributes
    changed[:scenario_stack] = { key: "move", layer_ids: %w[layer-1 layer-2] }
    b = Forecasts::Projection::Packet.new(changed)

    refute_equal a.scenario_stack_hash, b.scenario_stack_hash
  end

  # --- PlanIssue -----------------------------------------------------------

  def valid_issue_attributes
    {
      code: "missing_fx_rate",
      severity: "error",
      source: "source_snapshot",
      period: "2026-06",
      affected_entity_type: "account",
      affected_entity_id: "33333333-3333-3333-3333-333333333333",
      display_name: "N26 Checking",
      message_key: "forecast.issues.missing_fx_rate",
      impact: "Cash and net worth shown without this account for the selected period.",
      actions: %w[fetch_rates enter_fallback_rate exclude_account],
      debug_context: { from_currency: "EUR", to_currency: "USD", rate_date: "2026-06-01" }
    }
  end

  test "builds a PlanIssue with required fields" do
    issue = Forecasts::Projection::PlanIssue.new(valid_issue_attributes)

    assert_equal "missing_fx_rate", issue.code
    assert_equal "error", issue.severity
    assert_equal "source_snapshot", issue.source
    assert_equal "account", issue.affected_entity_type
    assert_equal %w[fetch_rates enter_fallback_rate exclude_account], issue.actions
    assert issue.frozen?
  end

  test "PlanIssue raises typed validation error when code is missing" do
    attrs = valid_issue_attributes.except(:code)

    assert_raises(Forecasts::Projection::PlanIssue::InvalidIssueError) do
      Forecasts::Projection::PlanIssue.new(attrs)
    end
  end

  test "PlanIssue raises typed validation error for unknown severity" do
    attrs = valid_issue_attributes.merge(severity: "catastrophic")

    error = assert_raises(Forecasts::Projection::PlanIssue::InvalidIssueError) do
      Forecasts::Projection::PlanIssue.new(attrs)
    end
    assert_match(/severity/, error.message)
  end

  test "PlanIssue tolerates optional fields being absent" do
    minimal = {
      code: "stale_source_data",
      severity: "warning",
      source: "source_snapshot",
      message_key: "forecast.issues.stale_source_data"
    }

    issue = Forecasts::Projection::PlanIssue.new(minimal)

    assert_nil issue.period
    assert_nil issue.affected_entity_id
    assert_equal [], issue.actions
    assert_equal({}, issue.debug_context)
  end

  # --- Trace ---------------------------------------------------------------

  def valid_trace_attributes
    {
      id: "trace-2026-06-salary-1",
      period_key: "2026-06",
      source_type: "assumption",
      source_id: "44444444-4444-4444-4444-444444444444",
      assumption_id: "44444444-4444-4444-4444-444444444444",
      scenario_layer_id: nil,
      flow_id: "flow-salary-1",
      category: "income",
      amount: "9500.00",
      currency: "USD",
      direction: "inflow",
      display_name: "Salary",
      explanation_key: "forecast.traces.salary",
      source_record_refs: [ { type: "payroll", id: "55555555-5555-5555-5555-555555555555" } ]
    }
  end

  test "builds a Trace with required fields and money as a string" do
    trace = Forecasts::Projection::Trace.new(valid_trace_attributes)

    assert_equal "2026-06", trace.period_key
    assert_equal "income", trace.category
    assert_equal "9500.00", trace.amount
    assert_kind_of String, trace.amount
    assert_equal "inflow", trace.direction
    assert trace.frozen?
  end

  test "Trace rejects float amounts to keep money as decimal strings" do
    attrs = valid_trace_attributes.merge(amount: 9500.0)

    error = assert_raises(Forecasts::Projection::Trace::InvalidTraceError) do
      Forecasts::Projection::Trace.new(attrs)
    end
    assert_match(/amount/, error.message)
  end

  test "Trace raises typed validation error for unknown category" do
    attrs = valid_trace_attributes.merge(category: "teleportation")

    assert_raises(Forecasts::Projection::Trace::InvalidTraceError) do
      Forecasts::Projection::Trace.new(attrs)
    end
  end

  test "Trace raises typed validation error for unknown direction" do
    attrs = valid_trace_attributes.merge(direction: "sideways")

    assert_raises(Forecasts::Projection::Trace::InvalidTraceError) do
      Forecasts::Projection::Trace.new(attrs)
    end
  end

  # --- Result envelope -----------------------------------------------------

  def valid_result_attributes
    {
      schema_version: 1,
      engine_version: "forecast_v2.1",
      input_packet_hash: "abc123",
      source_snapshot_hash: "def456",
      scenario_stack_hash: "ghi789",
      plan_version: 7,
      status: "clean",
      periods: [
        {
          key: "2026-06",
          granularity: "month",
          starts_on: "2026-06-01",
          ends_on: "2026-06-30",
          metrics: {
            net_worth: "100000.00",
            liquid_cash: "25000.00",
            income: "8000.00",
            spending: "5200.00",
            debt_balance: "30000.00",
            portfolio_value: "75000.00",
            runway_days: 145
          },
          trace_ids: [ "trace-2026-06-salary-1" ],
          issue_ids: []
        }
      ],
      series: [],
      traces: [ valid_trace_attributes ],
      issues: [ valid_issue_attributes ],
      goals: [],
      summary: { status: "clean", computed_at: "2026-06-01T00:00:00Z" }
    }
  end

  test "builds a Result envelope from a valid attribute hash" do
    result = Forecasts::Projection::Result.new(valid_result_attributes)

    assert_equal 1, result.schema_version
    assert_equal "forecast_v2.1", result.engine_version
    assert_equal "clean", result.status
    assert_equal 7, result.plan_version
    assert_equal 1, result.periods.length
    assert_equal "2026-06", result.periods.first.fetch(:key)
    assert result.frozen?
  end

  test "Result coerces nested issues and traces into typed value objects" do
    result = Forecasts::Projection::Result.new(valid_result_attributes)

    assert_kind_of Forecasts::Projection::PlanIssue, result.issues.first
    assert_kind_of Forecasts::Projection::Trace, result.traces.first
    assert_equal "missing_fx_rate", result.issues.first.code
    assert_equal "9500.00", result.traces.first.amount
  end

  test "Result raises typed validation error for unknown status" do
    attrs = valid_result_attributes.merge(status: "exploded")

    error = assert_raises(Forecasts::Projection::Result::InvalidResultError) do
      Forecasts::Projection::Result.new(attrs)
    end
    assert_match(/status/, error.message)
  end

  test "Result raises typed validation error when engine_version is missing" do
    attrs = valid_result_attributes.except(:engine_version)

    assert_raises(Forecasts::Projection::Result::InvalidResultError) do
      Forecasts::Projection::Result.new(attrs)
    end
  end

  test "Result accepts the three contract statuses" do
    %w[clean issue_limited blocked].each do |status|
      result = Forecasts::Projection::Result.new(valid_result_attributes.merge(status: status))
      assert_equal status, result.status
    end
  end

  test "Result#to_h round-trips through serialization deterministically" do
    a = Forecasts::Projection::Result.new(valid_result_attributes)
    b = Forecasts::Projection::Result.new(JSON.parse(a.to_h.to_json))

    assert_equal a.to_h, b.to_h
  end
end
