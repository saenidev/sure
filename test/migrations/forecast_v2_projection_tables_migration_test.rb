# frozen_string_literal: true

require "test_helper"

# Slice B2: proves the V2 source-snapshot + projection read/cache tables migrate
# round-trip and enforce their JSONB columns and partial-unique constraint.
# Uses raw SQL so it does not depend on the B3 ActiveRecord models or fixtures.
class ForecastV2ProjectionTablesMigrationTest < ActiveSupport::TestCase
  setup do
    @conn = ActiveRecord::Base.connection
    @family_id = insert_family
    @plan_id = insert_plan(@family_id)
  end

  test "source snapshot row round-trips jsonb columns" do
    id = SecureRandom.uuid
    @conn.execute(<<~SQL)
      INSERT INTO forecast_source_snapshots
        (id, forecast_plan_id, family_id, source_snapshot_hash, as_of, freshness_state,
         included_account_ids, source_versions, issue_candidates, snapshot_payload,
         schema_version, created_at, updated_at)
      VALUES
        ('#{id}', '#{@plan_id}', '#{@family_id}', 'hash-abc', '2026-06-06', 'fresh',
         '["acct-1","acct-2"]', '{"plaid":3}', '[{"code":"missing_fx_rate"}]', '{"balances":{}}',
         'forecast-source-snapshot-v1', now(), now())
    SQL

    row = select_one("SELECT * FROM forecast_source_snapshots WHERE id = '#{id}'")
    assert_equal "hash-abc", row["source_snapshot_hash"]
    assert_equal [ "acct-1", "acct-2" ], JSON.parse(row["included_account_ids"])
    assert_equal({ "plaid" => 3 }, JSON.parse(row["source_versions"]))
    assert_equal [ { "code" => "missing_fx_rate" } ], JSON.parse(row["issue_candidates"])
  end

  test "projection cache enforces at most one current non-superseded key" do
    snapshot_id = insert_snapshot(@plan_id, @family_id)
    insert_cache(@plan_id, snapshot_id, status: "fresh")

    # Wrap the expected violation in a savepoint so the surrounding test
    # transaction stays usable for the following assertions.
    error = assert_raises(ActiveRecord::RecordNotUnique) do
      @conn.transaction(requires_new: true) do
        insert_cache(@plan_id, snapshot_id, status: "stale")
      end
    end
    assert_match "idx_forecast_projection_caches_current_key", error.message

    # A superseded cache with the same key is allowed alongside the current one.
    assert_nothing_raised do
      insert_cache(@plan_id, snapshot_id, status: "superseded")
    end
  end

  test "projection period and trace rows round-trip metric jsonb and cascade from cache" do
    snapshot_id = insert_snapshot(@plan_id, @family_id)
    cache_id = insert_cache(@plan_id, snapshot_id, status: "fresh")

    period_id = SecureRandom.uuid
    @conn.execute(<<~SQL)
      INSERT INTO forecast_projection_periods
        (id, forecast_projection_cache_id, forecast_plan_id, scenario_stack_key, period_key,
         period_start_on, period_end_on, granularity, metrics, issue_codes, active_assumption_ids,
         plan_version, engine_version, created_at, updated_at)
      VALUES
        ('#{period_id}', '#{cache_id}', '#{@plan_id}', 'base', '2026-06', '2026-06-01', '2026-06-30',
         'month', '{"ending_balance":"1234.56"}', '["missing_fx_rate"]', '["assm-1"]',
         1, 'engine-v1', now(), now())
    SQL

    trace_id = SecureRandom.uuid
    @conn.execute(<<~SQL)
      INSERT INTO forecast_projection_traces
        (id, forecast_projection_cache_id, period_key, granularity, metric_key, direction,
         amount, currency, trace_kind, source_record_refs, created_at, updated_at)
      VALUES
        ('#{trace_id}', '#{cache_id}', '2026-06', 'month', 'inflow', 'credit',
         500.0, 'USD', 'assumption', '{"refs":[]}', now(), now())
    SQL

    period = select_one("SELECT metrics FROM forecast_projection_periods WHERE id = '#{period_id}'")
    assert_equal({ "ending_balance" => "1234.56" }, JSON.parse(period["metrics"]))

    # Deleting the cache cascades to periods and traces.
    @conn.execute("DELETE FROM forecast_projection_caches WHERE id = '#{cache_id}'")
    assert_nil select_one("SELECT id FROM forecast_projection_periods WHERE id = '#{period_id}'")
    assert_nil select_one("SELECT id FROM forecast_projection_traces WHERE id = '#{trace_id}'")
  end

  private

    def select_one(sql)
      @conn.select_one(sql)
    end

    def insert_family
      id = SecureRandom.uuid
      @conn.execute(<<~SQL)
        INSERT INTO families (id, name, created_at, updated_at)
        VALUES ('#{id}', 'B2 Test Family', now(), now())
      SQL
      id
    end

    def insert_plan(family_id)
      id = SecureRandom.uuid
      @conn.execute(<<~SQL)
        INSERT INTO forecast_plans
          (id, family_id, name, status, horizon_start_on, horizon_end_on, reporting_currency,
           settings, source_policy, current_plan_version, schema_version, lock_version,
           created_at, updated_at)
        VALUES
          ('#{id}', '#{family_id}', 'B2 Plan', 'active', '2026-06-01', '2029-06-01', 'USD',
           '{}', '{}', 1, 'forecast-plan-v1', 0, now(), now())
      SQL
      id
    end

    def insert_snapshot(plan_id, family_id)
      id = SecureRandom.uuid
      @conn.execute(<<~SQL)
        INSERT INTO forecast_source_snapshots
          (id, forecast_plan_id, family_id, source_snapshot_hash, as_of, freshness_state,
           included_account_ids, source_versions, issue_candidates, snapshot_payload,
           schema_version, created_at, updated_at)
        VALUES
          ('#{id}', '#{plan_id}', '#{family_id}', 'snap-hash', '2026-06-06', 'fresh',
           '[]', '{}', '[]', '{}', 'forecast-source-snapshot-v1', now(), now())
      SQL
      id
    end

    def insert_cache(plan_id, snapshot_id, status:)
      id = SecureRandom.uuid
      @conn.execute(<<~SQL)
        INSERT INTO forecast_projection_caches
          (id, forecast_plan_id, forecast_source_snapshot_id, plan_version, scenario_stack_key,
           scenario_stack_hash, source_snapshot_hash, engine_version, status, issue_summary,
           created_at, updated_at)
        VALUES
          ('#{id}', '#{plan_id}', '#{snapshot_id}', 1, 'base', 'stack-hash', 'snap-hash',
           'engine-v1', '#{status}', '{}', now(), now())
      SQL
      id
    end
end
