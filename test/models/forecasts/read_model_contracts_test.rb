# frozen_string_literal: true

require "test_helper"

# Cross-cutting contract tests for the Forecast V2 per-surface read models
# (spec "Read Models", "Read Model Contracts", "UI Payload Contracts").
#
# Each read model answers exactly ONE UI question and:
#   - consumes already-loaded projection cache / period / trace rows + plan
#     records,
#   - NEVER calls the engine, enqueues recompute, or mutates records,
#   - NEVER parses the full projection-result JSON for first-viewport / selected
#     period paths,
#   - NEVER queries per assumption card, per issue, or per trace line,
#   - emits typed payloads of i18n keys + decimal-string money, not formatted
#     UI strings and not raw UUID-first messages.
class Forecasts::ReadModelContractsTest < ActiveSupport::TestCase
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
    @salary = add_salary
    @living = add_living_expense
    @snapshot = Forecasts::SourceSnapshotBuilder.new(plan: @plan, as_of: @as_of).build
    @cache = Forecasts::Projection::RecomputeCoordinator.new(
      plan: @plan, source_snapshot: @snapshot
    ).recompute
    @periods = @cache.forecast_projection_periods.ordered.to_a
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

  # --- PlanReadModel -------------------------------------------------------

  test "PlanReadModel answers what plan is open and how to frame it" do
    payload = Forecasts::PlanReadModel.new(plan: @plan, cache: @cache).to_h

    assert_equal @plan.id, payload[:id]
    assert_equal @plan.name, payload[:name]
    assert payload.key?(:active_lens)
    assert payload.key?(:scenario_stack)
    assert payload.key?(:freshness)
    assert payload.key?(:privacy)
    assert payload.key?(:actions)
    assert payload.key?(:latest_issue_summary)

    # Must NOT include chart series, full card details, editor values, or packets.
    refute payload.key?(:series), "PlanReadModel must not carry chart series"
    refute payload.key?(:cards), "PlanReadModel must not carry full assumption card details"
    refute payload.key?(:packet)
  end

  test "PlanReadModel scenario stack summary names the live cache stack" do
    stack = Forecasts::PlanReadModel.new(plan: @plan, cache: @cache).to_h[:scenario_stack]

    assert_equal @cache.scenario_stack_key, stack[:key]
    assert stack.key?(:layers)
  end

  test "PlanReadModel latest issue summary is privacy-safe counts and codes" do
    summary = Forecasts::PlanReadModel.new(plan: @plan, cache: @cache).to_h[:latest_issue_summary]

    assert summary.key?(:status)
    assert summary.key?(:issue_count)
    assert summary.key?(:codes)
  end

  # --- ProjectionBandReadModel ---------------------------------------------

  test "ProjectionBandReadModel answers what the chart should show" do
    payload = Forecasts::ProjectionBandReadModel.new(
      cache: @cache,
      periods: @periods,
      selected_period_key: @periods.first.period_key,
      selected_metric: "net_worth"
    ).to_h

    assert_equal "net_worth", payload[:selected_metric]
    assert_equal @periods.map(&:period_key), payload[:period_keys]
    assert_equal @periods.first.period_key, payload[:selected_marker]
    assert payload.key?(:series)
    assert payload.key?(:freshness)

    # One series point per period, carrying the selected metric value as a
    # decimal string from the indexed row (not formatted, not float).
    assert_equal @periods.length, payload[:series].length
    first_point = payload[:series].first
    assert_equal @periods.first.period_key, first_point[:period_key]
    assert_equal @periods.first.metrics["net_worth"], first_point[:value]

    # Must NOT include editor data, snapshot internals, or ActiveRecord records.
    refute payload.key?(:editor)
    refute payload[:series].any? { |p| p.is_a?(ActiveRecord::Base) }
  end

  test "ProjectionBandReadModel defaults the selected marker to the first period" do
    payload = Forecasts::ProjectionBandReadModel.new(
      cache: @cache, periods: @periods
    ).to_h

    assert_equal @periods.first.period_key, payload[:selected_marker]
    assert_equal "net_worth", payload[:selected_metric]
  end

  test "ProjectionBandReadModel builds the band with no per-period query" do
    periods = @periods
    cache = @cache
    assert_queries_count(max: 0) do
      Forecasts::ProjectionBandReadModel.new(
        cache: cache, periods: periods, selected_metric: "income"
      ).to_h
    end
  end

  # --- AssumptionGroupReadModel --------------------------------------------

  test "AssumptionGroupReadModel returns stable scannable card payloads" do
    assumptions = @plan.forecast_assumptions.to_a
    active_ids = @periods.first.active_assumption_ids

    payload = Forecasts::AssumptionGroupReadModel.new(
      assumptions: assumptions,
      active_assumption_ids: active_ids
    ).to_h

    assert payload.key?(:groups)
    refute_empty payload[:groups]

    salary_group = payload[:groups].find { |g| g[:kind] == "salary" }
    assert salary_group, "expected a salary group header"
    card = salary_group[:cards].first

    assert_equal @salary.id, card[:id]
    assert_equal "salary", card[:kind]
    assert card.key?(:icon)
    assert card.key?(:title)
    assert card.key?(:amount_summary)
    assert card.key?(:time_summary)
    assert card.key?(:behavior_summary)
    assert card.key?(:source_summary)
    assert card.key?(:status_badges)
    assert card.key?(:active_in_period)
    assert card.key?(:actions)
  end

  test "AssumptionGroupReadModel marks active-in-period from the passed ids" do
    assumptions = @plan.forecast_assumptions.to_a
    payload = Forecasts::AssumptionGroupReadModel.new(
      assumptions: assumptions,
      active_assumption_ids: [ @salary.id ]
    ).to_h

    salary_card = payload[:groups].flat_map { |g| g[:cards] }.find { |c| c[:id] == @salary.id }
    living_card = payload[:groups].flat_map { |g| g[:cards] }.find { |c| c[:id] == @living.id }

    assert salary_card[:active_in_period]
    refute living_card[:active_in_period]
  end

  test "AssumptionGroupReadModel surfaces review provenance badges" do
    @salary.update!(origin: :source_derived, review_state: :needs_review, confidence: :medium)
    assumptions = @plan.forecast_assumptions.reload.to_a

    card = Forecasts::AssumptionGroupReadModel.new(
      assumptions: assumptions, active_assumption_ids: []
    ).to_h[:groups].flat_map { |g| g[:cards] }.find { |c| c[:id] == @salary.id }

    assert_includes card[:status_badges], "review_suggested"
  end

  test "AssumptionGroupReadModel does no per-card query" do
    assumptions = @plan.forecast_assumptions.to_a # loaded once
    active_ids = [ @salary.id ]
    assert_queries_count(max: 0) do
      Forecasts::AssumptionGroupReadModel.new(
        assumptions: assumptions, active_assumption_ids: active_ids
      ).to_h
    end
  end

  # --- EditorPrefillReadModel ----------------------------------------------

  test "EditorPrefillReadModel returns one typed editor payload" do
    payload = Forecasts::EditorPrefillReadModel.new(assumption: @salary).to_h

    assert_equal "salary", payload[:form_key]
    assert_equal @salary.id, payload[:assumption_id]
    assert payload.key?(:scenario_layer_id)
    assert payload.key?(:primary_values)
    assert payload.key?(:section_summaries)
    assert payload.key?(:validation)

    # current values reflect the record
    assert_equal @salary.name, payload[:primary_values][:name]
    assert payload[:primary_values].key?(:amount)
    assert payload[:primary_values].key?(:currency)

    # Must NOT include other assumptions, chart series, or projection results.
    refute payload.key?(:series)
    refute payload.key?(:other_assumptions)
  end

  test "EditorPrefillReadModel carries the optimistic lock version for stale-edit protection" do
    validation = Forecasts::EditorPrefillReadModel.new(assumption: @salary).to_h[:validation]

    assert_equal @salary.lock_version, validation[:lock_version]
    assert validation.key?(:schema_version)
  end

  # --- IssueReadModel ------------------------------------------------------

  test "IssueReadModel renders a privacy-safe user-facing payload" do
    issue = Forecasts::Projection::PlanIssue.new(
      code: "missing_fx_rate",
      severity: "warning",
      source: "source_snapshot",
      period: @periods.first.period_key,
      affected_entity_type: "account",
      affected_entity_id: "11111111-2222-3333-4444-555555555555",
      display_name: "Portfolio value",
      message_key: "forecasts.issues.missing_fx_rate",
      impact: "Portfolio value may be understated for this period.",
      actions: %w[add_fx_rate],
      debug_context: { account_id: "11111111-2222-3333-4444-555555555555" }
    )

    payload = Forecasts::IssueReadModel.new(issue: issue).to_h

    assert_equal "missing_fx_rate", payload[:code]
    assert_equal "warning", payload[:severity]
    assert_equal "Portfolio value", payload[:title]
    assert payload.key?(:affected_output)
    assert payload.key?(:impact)
    assert_equal %w[add_fx_rate], payload[:actions]
    assert_equal "forecasts.issues.missing_fx_rate", payload[:message_key]

    # No raw UUIDs anywhere in the user-facing payload, and no debug_context.
    refute payload.key?(:debug_context), "IssueReadModel must not leak debug_context to the UI"
    flat = payload.to_a.flatten.map(&:to_s).join(" ")
    refute flat.match?(/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}/),
      "IssueReadModel payload must not contain raw UUIDs"
  end

  test "IssueReadModel accepts a plain issue hash" do
    payload = Forecasts::IssueReadModel.new(issue: {
      "code" => "stale_source_data",
      "severity" => "info",
      "source" => "source_snapshot",
      "message_key" => "forecasts.issues.stale_source_data",
      "display_name" => "Connected accounts",
      "impact" => "Some balances may be out of date.",
      "actions" => [ "resync" ]
    }).to_h

    assert_equal "stale_source_data", payload[:code]
    assert_equal "Connected accounts", payload[:title]
    assert_equal [ "resync" ], payload[:actions]
  end

  # --- shared invariants: never call the engine / never mutate -------------

  test "read models never call the engine" do
    Forecasts::Projection::Engine.expects(:call).never

    Forecasts::PlanReadModel.new(plan: @plan, cache: @cache).to_h
    Forecasts::ProjectionBandReadModel.new(cache: @cache, periods: @periods).to_h
    Forecasts::AssumptionGroupReadModel.new(
      assumptions: @plan.forecast_assumptions.to_a, active_assumption_ids: []
    ).to_h
    Forecasts::EditorPrefillReadModel.new(assumption: @salary).to_h
  end

  test "read models never enqueue recompute work" do
    Forecasts::Projection::RecomputeCoordinator.any_instance.expects(:recompute).never

    Forecasts::PlanReadModel.new(plan: @plan, cache: @cache).to_h
    Forecasts::ProjectionBandReadModel.new(cache: @cache, periods: @periods).to_h
  end

  test "read models do not mutate the records they read" do
    assert_no_difference [
      -> { Forecasts::ProjectionCache.count },
      -> { Forecasts::ProjectionPeriod.count },
      -> { Forecasts::Assumption.count }
    ] do
      Forecasts::PlanReadModel.new(plan: @plan, cache: @cache).to_h
      Forecasts::ProjectionBandReadModel.new(cache: @cache, periods: @periods).to_h
      Forecasts::AssumptionGroupReadModel.new(
        assumptions: @plan.forecast_assumptions.to_a, active_assumption_ids: []
      ).to_h
      Forecasts::EditorPrefillReadModel.new(assumption: @salary).to_h
    end
    refute @cache.changed?
    refute @salary.changed?
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
