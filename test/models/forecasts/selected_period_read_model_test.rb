# frozen_string_literal: true

require "test_helper"

# Tests for Forecasts::SelectedPeriodReadModel.
#
# This read model answers exactly ONE UI question: "what explains the currently
# selected month/year?" It is loaded from the indexed Forecasts::ProjectionPeriod
# row (whose `traces` jsonb blob embeds the per-period explanation traces) —
# NEVER by parsing the full projection-result JSON (spec "Read Model Contracts",
# "UI Payload Contracts").
#
# Critical contracts asserted here:
#   - reads the indexed period row, not the cache's full result JSON
#   - emits a metric strip, active_assumption_ids, trace-backed explanation lines,
#     period issues, and freshness state — as a typed payload of i18n keys, never
#     formatted strings
#   - no per-trace / per-issue query when explanation lines and issues are built
class Forecasts::SelectedPeriodReadModelTest < ActiveSupport::TestCase
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
    @cache = Forecasts::Projection::RecomputeCoordinator.new(
      plan: @plan, source_snapshot: @snapshot
    ).recompute
    @period = @cache.forecast_projection_periods.ordered.first
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

  def build_model(period: @period, cache: @cache)
    Forecasts::SelectedPeriodReadModel.new(period: period, cache: cache)
  end

  # --- payload shape -------------------------------------------------------

  test "exposes the documented selected-period payload shape" do
    payload = build_model.to_h

    assert_equal @period.period_key, payload[:period_key]
    assert_equal "month", payload[:granularity]
    assert payload.key?(:selected_metric)
    assert payload.key?(:metrics)
    assert payload.key?(:active_assumption_ids)
    assert payload.key?(:explanation)
    assert payload.key?(:issues)
    assert payload.key?(:freshness)
  end

  test "metric strip is built from the indexed period row metrics" do
    metrics = build_model.to_h[:metrics]

    keys = metrics.map { |m| m[:key] }
    assert_includes keys, "net_worth"
    assert_includes keys, "income"
    assert_includes keys, "spending"

    income = metrics.find { |m| m[:key] == "income" }
    # Values are the decimal-string period metrics, not floats or formatted money.
    assert_equal "6000.00", income[:value]
    assert income.key?(:label_key), "metric strip entries expose an i18n label key, not a formatted label"
  end

  test "active_assumption_ids come from the period row, not a re-query" do
    payload = build_model.to_h

    assert_equal @period.active_assumption_ids.sort, payload[:active_assumption_ids].sort
    refute_empty payload[:active_assumption_ids]
  end

  test "explanation lines are derived from the period's embedded traces" do
    explanation = build_model.to_h[:explanation]

    refute_empty explanation
    line = explanation.first
    assert line.key?(:kind)
    assert line.key?(:amount)
    assert line.key?(:explanation_key)
    assert_equal "trace", line[:source]

    # Each explanation line maps one embedded trace entry; counts match the
    # period row's stored trace blob.
    assert_equal @period.traces.length, explanation.length

    income_line = explanation.find { |l| l[:kind] == "income" }
    assert_equal "6000.00", income_line[:amount]
  end

  test "issues are the privacy-safe period issue codes from the row" do
    # Force a period issue code onto the row to prove it is surfaced.
    @period.update!(issue_codes: [ "missing_fx_rate" ])
    payload = build_model(period: @period.reload).to_h

    assert_equal [ "missing_fx_rate" ], payload[:issues].map { |i| i[:code] }
    issue = payload[:issues].first
    assert issue.key?(:severity)
    refute issue.to_s.match?(/[0-9a-f]{8}-[0-9a-f]{4}/), "issues must not leak raw UUIDs"
  end

  test "freshness reflects the cache status" do
    freshness = build_model.to_h[:freshness]

    assert_equal "fresh", freshness[:state]
    assert freshness.key?(:projected_at)
  end

  # --- the load contract: rows, not full JSON ------------------------------

  test "does not read the cache projection result JSON" do
    # The cache row carries only a result HASH, never the full result body — there
    # is no full-JSON column to parse. This guards the contract structurally: the
    # read model is constructed from the period row the coordinator indexed
    # (traces embedded on it), and the cache contributes only freshness metadata.
    refute @cache.respond_to?(:projection_result),
      "the cache must not expose a full projection-result JSON body for read models to parse"
    refute @cache.attributes.key?("projection_result"),
      "no full projection-result JSON column exists; reads must use indexed rows"

    payload = build_model.to_h
    assert payload[:metrics].present?
    assert payload[:explanation].present?
  end

  # --- no per-trace / per-issue queries ------------------------------------

  test "building the payload issues no per-trace or per-issue queries" do
    # The period row (traces embedded) is already loaded in setup; assembling
    # the payload must not lazy-load any additional row (spec: "No read model
    # may query ... per issue, per trace line").
    model = build_model
    assert_queries_count(max: 0) do
      payload = model.to_h
      payload[:explanation].each { |line| line[:amount] }
      payload[:issues].each { |issue| issue[:code] }
      payload[:metrics].each { |metric| metric[:value] }
    end
  end

  private
    def assert_queries_count(max:)
      queries = []
      callback = ->(_name, _start, _finish, _id, payload) do
        sql = payload[:sql]
        queries << sql if sql && !payload[:name].to_s.include?("SCHEMA") && sql.match?(/SELECT/)
      end
      ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { yield }
      assert queries.size <= max, "expected at most #{max} queries, got #{queries.size}:\n#{queries.join("\n")}"
    end
end
