# frozen_string_literal: true

require "test_helper"

# Tests for the Forecast V2 source snapshot builder. The builder reads connected
# family data (accounts/balances, recurring transactions, budgets, FX rates,
# holdings/prices), threaded by an explicit `as_of` date, and normalizes it into
# the engine's serializable `source_snapshot` shape. It computes a stable
# `source_snapshot_hash`, captures `freshness_state`, `included_account_ids`, and
# `issue_candidates` (e.g. missing-FX candidates), and persists a
# Forecasts::SourceSnapshot row that is reused by hash. It is family-scoped via
# the plan and never trusts a family_id from params. See spec "Source Snapshot",
# "Source Snapshot Tables", "Source-To-Assumption Mapping".
class Forecasts::SourceSnapshotBuilderTest < ActiveSupport::TestCase
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
  end

  def build(as_of: @as_of)
    Forecasts::SourceSnapshotBuilder.new(plan: @plan, as_of: as_of).build
  end

  test "builds and persists a source snapshot row scoped to the plan and family" do
    snapshot = nil
    assert_difference -> { Forecasts::SourceSnapshot.count }, 1 do
      snapshot = build
    end

    assert_equal @plan.id, snapshot.forecast_plan_id
    assert_equal @family.id, snapshot.family_id
    assert_equal @as_of, snapshot.as_of
    assert snapshot.source_snapshot_hash.present?
    assert snapshot.persisted?
  end

  test "produces a stable hash for stable inputs" do
    first = build
    # No data changed between calls; the normalized payload must hash identically.
    second_hash = Forecasts::SourceSnapshotBuilder.new(plan: @plan, as_of: @as_of).send(:compute)[:source_snapshot_hash]

    assert_equal first.source_snapshot_hash, second_hash
  end

  test "is idempotent by hash: re-running with the same inputs reuses the row" do
    first = build

    assert_no_difference -> { Forecasts::SourceSnapshot.count } do
      second = build
      assert_equal first.id, second.id
      assert_equal first.source_snapshot_hash, second.source_snapshot_hash
    end
  end

  test "rebuilds a new row when source data changes the hash" do
    first = build

    # Change connected data: add a new active recurring transaction.
    @family.recurring_transactions.create!(
      account: accounts(:depository),
      name: "Gym",
      amount: 50,
      currency: "USD",
      expected_day_of_month: 1,
      last_occurrence_date: @as_of - 1.month,
      next_expected_date: @as_of + 1.month,
      status: "active",
      occurrence_count: 3
    )

    second = nil
    assert_difference -> { Forecasts::SourceSnapshot.count }, 1 do
      second = build
    end

    assert_not_equal first.source_snapshot_hash, second.source_snapshot_hash
    assert_not_equal first.id, second.id
  end

  test "normalizes payload into the engine source_snapshot shape" do
    snapshot = build
    payload = snapshot.snapshot_payload.deep_symbolize_keys

    assert_equal "USD", payload[:reporting_currency]
    # as_of is serialized so the pure engine never reads Date.current.
    assert payload[:as_of].present?
    assert payload.key?(:opening_balances)
    assert payload.key?(:accounts)
    assert payload.key?(:recurring_patterns)
    assert payload.key?(:budgets)
    assert payload.key?(:holdings)
    assert payload.key?(:prices)
    assert payload.key?(:fx_rates)

    # Money is serialized as decimal strings, never floats.
    payload[:opening_balances].each_value do |amount|
      assert_kind_of String, amount
    end
  end

  test "captures included_account_ids for visible family accounts" do
    snapshot = build
    visible_ids = @family.accounts.visible.pluck(:id)

    assert_equal visible_ids.sort, snapshot.included_account_ids.sort
    assert visible_ids.any?, "fixture should have visible accounts"
  end

  test "respects as_of: a later as_of selects FX rates dated on or before it" do
    # An account in a non-reporting currency with an FX rate available as_of.
    foreign = @family.accounts.create!(
      name: "Euro Cash",
      balance: 1000,
      currency: "EUR",
      accountable: Depository.new
    )
    ExchangeRate.create!(from_currency: "EUR", to_currency: "USD", rate: 1.10, date: @as_of - 10.days)

    snapshot = build(as_of: @as_of)
    fx_rates = snapshot.snapshot_payload.deep_symbolize_keys[:fx_rates]
    eur_rate = fx_rates.find { |r| r[:from] == "EUR" && r[:to] == "USD" }

    assert eur_rate.present?, "FX rate dated on or before as_of should be included"
    assert_includes snapshot.included_account_ids, foreign.id
  end

  test "captures missing-FX issue candidates when no rate exists for a foreign account" do
    @family.accounts.create!(
      name: "Yen Cash",
      balance: 500_000,
      currency: "JPY",
      accountable: Depository.new
    )
    # No EUR/JPY -> USD rate exists as_of.

    snapshot = build
    codes = snapshot.issue_candidates.map { |c| c.deep_symbolize_keys[:code] }

    assert_includes codes, "missing_fx_rate"
    missing = snapshot.issue_candidates
      .map { |c| c.deep_symbolize_keys }
      .find { |c| c[:code] == "missing_fx_rate" }
    assert_equal "JPY", missing[:currency]
  end

  test "no missing-FX candidate when every foreign account has a rate" do
    @family.accounts.create!(
      name: "Pound Cash",
      balance: 1000,
      currency: "GBP",
      accountable: Depository.new
    )
    ExchangeRate.create!(from_currency: "GBP", to_currency: "USD", rate: 1.25, date: @as_of)

    snapshot = build
    codes = snapshot.issue_candidates.map { |c| c.deep_symbolize_keys[:code] }

    assert_not_includes codes, "missing_fx_rate"
  end

  test "marks an existing fresh snapshot stale when its hash no longer matches" do
    first = build

    # Mutate data so the recomputed hash differs; the old fresh snapshot for the
    # plan should be marked stale rather than left dangling as fresh.
    accounts(:depository).update!(balance: 99_999)

    second = build
    assert_not_equal first.id, second.id
    assert_equal "fresh", second.freshness_state
    assert_equal "stale", first.reload.freshness_state
  end

  test "does not trust a family_id from params: scope comes from the plan" do
    other_family = families(:empty)
    other_plan = Forecasts::Plan.create!(
      family: other_family,
      name: "Other",
      horizon_start_on: @as_of,
      horizon_end_on: @as_of >> 12,
      reporting_currency: "USD"
    )

    snapshot = Forecasts::SourceSnapshotBuilder.new(plan: other_plan, as_of: @as_of).build

    assert_equal other_family.id, snapshot.family_id
    # The other family has no accounts; the snapshot must not leak dylan's data.
    assert_empty snapshot.included_account_ids
  end
end
