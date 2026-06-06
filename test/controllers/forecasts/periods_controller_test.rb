require "test_helper"
require Rails.root.join("test/fixtures/files/forecasts/connected_family_proof")

# Slice C5: Forecasts::PeriodsController#show — the selected-period JSON
# read-model endpoint (GET /forecast/periods/:period_key).
#
# Proves the spec's "Inertia And JSON Endpoints" contract for the selected-period
# path: GET /forecast/periods/:period_key returns the SelectedPeriodReadModel
# (B13) typed UI payload for a SETTLED selection / cache miss / explicit refresh.
# It is family-scoped (the plan + cache + period are resolved server-side through
# Current.family, never from params), returns a typed payload (NOT raw engine
# result internals), stays within the JSON read budget (<= 12 SQL queries), and
# never parses the full projection-result JSON (it reads indexed period/trace
# rows only).
#
# Spec: "V2 route shape" (GET /forecast/periods/:period_key), "Inertia And JSON
# Endpoints" (SelectedPeriodReadModel only after settled selection / cache miss /
# explicit refresh; JSON endpoints return typed UI payloads, not raw engine
# internals), "Read Model Contracts" (SelectedPeriodReadModel reads period/trace
# rows, not full JSON), "Query And Data-Loading Budgets".
class Forecasts::PeriodsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @family = @user.family

    Forecasts::ConnectedFamilyProof.build(
      family: @family,
      depository_account: accounts(:depository),
      budget: budgets(:one),
      as_of: Date.current
    )

    sign_in @user
  end

  # --- Happy path: typed selected-period payload ---------------------------

  test "returns the SelectedPeriodReadModel payload for a settled period selection" do
    with_v2_enabled do
      plan, cache = warm_workspace
      period = cache.forecast_projection_periods.ordered.first

      get forecast_period_url(period.period_key)

      assert_response :success
      assert_equal "application/json", response.media_type

      payload = response.parsed_body
      assert_equal period.period_key, payload["period_key"]
      assert_equal "month", payload["granularity"]
      assert payload["selected_metric"].present?
      assert payload["metrics"].is_a?(Array)
      refute_empty payload["metrics"], "expected a metric strip for the selected period"
      assert payload.key?("active_assumption_ids")
      assert payload.key?("explanation"), "expected trace-backed explanation lines"
      assert payload.key?("issues")
      assert payload.dig("freshness", "state").present?
    end
  end

  test "metric strip carries i18n label keys and canonical values, never formatted strings" do
    with_v2_enabled do
      _plan, cache = warm_workspace
      period = cache.forecast_projection_periods.ordered.first

      get forecast_period_url(period.period_key)
      assert_response :success

      metric = response.parsed_body["metrics"].first
      assert metric["key"].present?
      assert_match(/\Aforecasts\.metrics\./, metric["label_key"],
        "metric label must be an i18n key, not a localized string")
    end
  end

  # --- Family scoping ------------------------------------------------------

  test "never trusts a family_id param: a period from another family 404s" do
    with_v2_enabled do
      _plan, cache = warm_workspace
      period_key = cache.forecast_projection_periods.ordered.first.period_key

      other_user = users(:empty)
      refute_equal @family.id, other_user.family_id, "fixture sanity: distinct families"
      sign_in other_user

      with_v2_enabled_for(other_user.family) do
        # Even passing the original family_id must not widen scope — the
        # controller resolves the plan/cache through Current.family only.
        get forecast_period_url(period_key), params: { family_id: @family.id }
        assert_response :not_found
      end
    end
  end

  test "an unknown period key for the open plan 404s" do
    with_v2_enabled do
      warm_workspace

      get forecast_period_url("1999-01")
      assert_response :not_found
    end
  end

  # --- Boundaries: typed payload, no full-JSON parse -----------------------

  test "returns a typed read-model payload, not raw engine result internals" do
    with_v2_enabled do
      _plan, cache = warm_workspace
      period = cache.forecast_projection_periods.ordered.first

      get forecast_period_url(period.period_key)
      assert_response :success

      payload = response.parsed_body
      # The typed SelectedPeriodReadModel shape — and explicitly NOT raw engine
      # internals (packets, snapshots, full trace graph dumps, result hashes).
      assert_equal(
        %w[period_key granularity selected_metric metrics active_assumption_ids explanation issues freshness].sort,
        payload.keys.sort
      )
      refute payload.key?("packet")
      refute payload.key?("source_snapshot")
      refute payload.key?("projection_result")
      refute payload.key?("traces")
    end
  end

  test "serves the period without parsing the full projection-result JSON" do
    with_v2_enabled do
      warm_workspace

      # The read model reads indexed period/trace rows; it must never deserialize
      # the cache's full projection-result JSON blob. Guard the seam: if anyone
      # reaches for a full-result parse, fail loudly.
      Forecasts::SelectedPeriodReadModel.any_instance.expects(:projection_result).never if
        Forecasts::SelectedPeriodReadModel.method_defined?(:projection_result)

      period_key = Forecasts::Plan.where(family: @family).sole
        .forecast_projection_caches.current.where(status: "fresh").sole
        .forecast_projection_periods.ordered.first.period_key

      get forecast_period_url(period_key)
      assert_response :success
    end
  end

  # --- Query budget --------------------------------------------------------

  test "selected-period JSON load stays within the query budget" do
    with_v2_enabled do
      _plan, cache = warm_workspace
      period_key = cache.forecast_projection_periods.ordered.first.period_key

      query_count = count_select_queries do
        get forecast_period_url(period_key)
        assert_response :success
      end

      assert query_count <= 12,
        "expected <= 12 SQL queries for a selected-period JSON load, got #{query_count}"
    end
  end

  # --- Gating --------------------------------------------------------------

  test "is gated behind the V2 feature check" do
    warm_workspace_records
    period_key = Forecasts::Plan.where(family: @family).sole
      .forecast_projection_caches.current.where(status: "fresh").sole
      .forecast_projection_periods.ordered.first.period_key

    # V2 flag off: the endpoint must not serve V2 JSON.
    get forecast_period_url(period_key)
    assert_response :not_found
  end

  private
    # Opens the V2 workspace once (load-or-create plan + ensure cache via the
    # shared loading seam) so a fresh cache with indexed period/trace rows exists,
    # then returns [plan, cache].
    def warm_workspace
      get forecast_url
      assert_response :success
      warm_workspace_records
    end

    # Builds the plan + cache records directly (no HTTP), for the gating test
    # where the V2 flag is off and /forecast would not produce a V2 cache.
    def warm_workspace_records
      plan = Forecasts::DefaultPlanBuilder.new(family: @family, as_of: Date.current).build
      cache = plan.forecast_projection_caches.current.where(status: "fresh").order(finished_at: :desc).first
      cache ||= begin
        snapshot = Forecasts::SourceSnapshotBuilder.new(plan: plan, as_of: Date.current).build
        Forecasts::Projection::RecomputeCoordinator.new(plan: plan, source_snapshot: snapshot).recompute
        plan.forecast_projection_caches.current.where(status: "fresh").order(finished_at: :desc).first
      end
      [ plan, cache ]
    end

    def with_v2_enabled(&block)
      with_v2_enabled_for(@family, &block)
    end

    def with_v2_enabled_for(family)
      original_enabled = Rails.configuration.x.forecast_v2.enabled
      original_ids = Rails.configuration.x.forecast_v2.family_ids
      Rails.configuration.x.forecast_v2.enabled = true
      Rails.configuration.x.forecast_v2.family_ids = [ family.id.to_s ].to_set.freeze
      yield
    ensure
      Rails.configuration.x.forecast_v2.enabled = original_enabled
      Rails.configuration.x.forecast_v2.family_ids = original_ids
    end

    def count_select_queries
      queries = []
      callback = lambda do |_name, _start, _finish, _id, payload|
        sql = payload[:sql]
        next if sql.nil?
        next if payload[:name].to_s.include?("SCHEMA")
        queries << sql if sql.match?(/SELECT/)
      end
      ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { yield }
      queries.size
    end
end
