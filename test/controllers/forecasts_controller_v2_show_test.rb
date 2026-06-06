require "test_helper"
require "inertia_rails/minitest"
require Rails.root.join("test/fixtures/files/forecasts/connected_family_proof")

# Slice C2: ForecastsController#show V2 path.
#
# Proves that, when the V2 feature check passes at the canonical /forecast URL,
# #show loads-or-creates the family's default plan (B10), ensures a current
# projection cache exists (B12, built through the recompute coordinator if
# missing), and renders the Forecast/Workspace Inertia page (C3) with
# first-viewport props assembled from the per-surface read models (B13).
#
# Spec: "Controllers" (ForecastsController#show), "Inertia And JSON Endpoints"
# (initial props), "Query And Data-Loading Budgets" (load /forecast with an
# existing plan + cached latest result is <= 35 SQL queries), "First Viewport
# Contract", "Read Model Contracts".
#
# Hard boundaries asserted: the V2 path never instantiates the V1
# Forecast::Workspace, never runs projection math inline except through the
# recompute coordinator, and creates exactly one plan no matter how many times
# /forecast is opened (idempotent plan creation).
class ForecastsControllerV2ShowTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @family = @user.family

    # Shape the connected family into the default-plan scenario (recurring
    # payroll inflow + current budget), anchored to the same clock the
    # controller threads as its as_of so the derived assumptions line up.
    Forecasts::ConnectedFamilyProof.build(
      family: @family,
      depository_account: accounts(:depository),
      budget: budgets(:one),
      as_of: Date.current
    )

    sign_in @user
  end

  # --- Component + first-viewport prop regions -----------------------------

  test "renders the Forecast/Workspace Inertia component with all first-viewport prop regions" do
    with_v2_enabled do
      get forecast_url

      assert_response :success
      assert_inertia_component "Forecast/Workspace"

      # Every first-viewport region the spec's "First Viewport Contract" +
      # "Inertia And JSON Endpoints" initial-props contract requires, each
      # sourced from its own read model.
      %i[plan band selectedPeriod assumptionGroups issues freshness].each do |region|
        assert inertia.props.key?(region), "expected Inertia props to include #{region}"
      end
    end
  end

  test "plan prop carries plan identity and server-derived currency" do
    with_v2_enabled do
      get forecast_url

      plan = inertia.props[:plan]
      assert plan[:id].present?, "expected plan.id"
      assert plan[:name].present?, "expected plan.name"
      assert_equal @family.primary_currency_code, plan[:reporting_currency]
      assert plan.key?(:active_lens), "expected plan.active_lens (lens nav)"
      assert plan.key?(:scenario_stack), "expected plan.scenario_stack summary"
    end
  end

  test "band prop carries the chart series and a selected marker" do
    with_v2_enabled do
      get forecast_url

      band = inertia.props[:band]
      assert band[:period_keys].is_a?(Array)
      refute_empty band[:period_keys], "expected at least one projected period"
      assert band[:series].is_a?(Array)
      assert_equal band[:period_keys], band[:series].map { |point| point[:period_key] },
        "expected one series point per period key, in order"
      assert_includes band[:period_keys], band[:selected_marker]
    end
  end

  test "selected-period prop seeds the default period metric strip and explanation" do
    with_v2_enabled do
      get forecast_url

      selected = inertia.props[:selectedPeriod]
      assert selected[:period_key].present?, "expected a seeded selected period key"
      assert_equal inertia.props.dig(:band, :selected_marker), selected[:period_key],
        "the seeded selected period must match the band's selected marker"
      refute_empty selected[:metrics], "expected a metric strip for the selected period"
      assert selected.key?(:explanation), "expected trace-backed explanation lines"
    end
  end

  test "assumption-group prop exposes the derived assumption cards" do
    with_v2_enabled do
      get forecast_url

      groups = inertia.props.dig(:assumptionGroups, :groups)
      assert groups.is_a?(Array)
      kinds = groups.map { |group| group[:kind] }
      assert_includes kinds, "salary"
      assert_includes kinds, "living_expense"
    end
  end

  test "issues and freshness props are present and typed" do
    with_v2_enabled do
      get forecast_url

      assert inertia.props[:issues].is_a?(Array), "expected an issue summary list"
      freshness = inertia.props[:freshness]
      assert_includes %w[fresh stale recomputing failed superseded uncomputed], freshness[:state]
    end
  end

  # --- Idempotent plan + cache creation ------------------------------------

  test "creates exactly one plan no matter how many times /forecast is opened" do
    with_v2_enabled do
      assert_difference -> { Forecasts::Plan.where(family: @family).count }, 1 do
        get forecast_url
        assert_response :success
      end

      assert_no_difference -> { Forecasts::Plan.where(family: @family).count } do
        3.times do
          get forecast_url
          assert_response :success
        end
      end
    end
  end

  test "does not rebuild the projection cache when a fresh one already exists" do
    with_v2_enabled do
      get forecast_url
      assert_response :success

      plan = Forecasts::Plan.where(family: @family).sole

      assert_no_difference -> { Forecasts::ProjectionCache.where(forecast_plan: plan).count } do
        get forecast_url
        assert_response :success
      end
    end
  end

  # --- Boundaries: no V1, no inline math -----------------------------------

  test "the V2 show path never instantiates the V1 Forecast::Workspace" do
    with_v2_enabled do
      Forecast::Workspace.expects(:new).never

      get forecast_url

      assert_response :success
      assert_inertia_component "Forecast/Workspace"
    end
  end

  test "builds a missing projection cache through the recompute coordinator on a cold load" do
    with_v2_enabled do
      # A cold load (no cache yet) must reach the coordinator seam — the
      # controller never runs projection math inline (the engine is only ever
      # reached from inside the coordinator). Returning nil here means no cache is
      # published; the read models tolerate a nil cache, so the page still renders.
      Forecasts::Projection::RecomputeCoordinator.any_instance.expects(:recompute).at_least_once.returns(nil)

      get forecast_url

      assert_response :success
      assert_inertia_component "Forecast/Workspace"
    end
  end

  test "a cold load persists a fresh projection cache for the new plan" do
    with_v2_enabled do
      assert_difference -> { Forecasts::ProjectionCache.where(status: "fresh").count }, 1 do
        get forecast_url
        assert_response :success
      end

      plan = Forecasts::Plan.where(family: @family).sole
      cache = Forecasts::ProjectionCache.where(forecast_plan: plan).current.where(status: "fresh").sole
      assert cache.forecast_projection_periods.count.positive?,
        "the cold-load cache must index period rows the band/selected-period props read from"
    end
  end

  # --- Query / data-loading budget -----------------------------------------

  test "loading /forecast with an existing plan and cached result stays within the query budget" do
    with_v2_enabled do
      # Warm the plan + cache so this measures the steady-state load path.
      get forecast_url
      assert_response :success

      query_count = count_select_queries do
        get forecast_url
        assert_response :success
      end

      assert query_count <= 35,
        "expected <= 35 SQL queries for a warm /forecast load, got #{query_count}"
    end
  end

  private
    # Enables the V2 feature check for the test family at the canonical /forecast
    # URL, restoring the prior config afterward.
    def with_v2_enabled
      original_enabled = Rails.configuration.x.forecast_v2.enabled
      original_ids = Rails.configuration.x.forecast_v2.family_ids
      Rails.configuration.x.forecast_v2.enabled = true
      Rails.configuration.x.forecast_v2.family_ids = [ @family.id.to_s ].to_set.freeze
      yield
    ensure
      Rails.configuration.x.forecast_v2.enabled = original_enabled
      Rails.configuration.x.forecast_v2.family_ids = original_ids
    end

    # Counts SELECT queries issued inside the block, ignoring schema and
    # transaction-control statements (mirrors the read-model contract helper).
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
