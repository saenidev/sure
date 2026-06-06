require "test_helper"
require "inertia_rails/minitest"
require Rails.root.join("test/fixtures/files/forecasts/connected_family_proof")

# Dedicated /forecast_v2 route (ForecastsController#v2).
#
# Unlike #show (which is gated behind Forecasts::V2Flag at the canonical
# /forecast URL), this route renders the V2 Inertia workspace UNCONDITIONALLY —
# no FORECAST_V2_ENABLED, no family allowlist, no user preview. Opening the URL
# is enough. It reuses the same family-scoped WorkspaceLoading seam as the gated
# path, so the load-or-create-plan + ensure-cache + first-viewport props behave
# identically; only the flag requirement is removed.
class ForecastsControllerV2RouteTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @family = @user.family

    Forecasts::ConnectedFamilyProof.build(
      family: @family,
      depository_account: accounts(:depository),
      budget: budgets(:one),
      as_of: Date.current
    )

    # Deliberately leave the V2 flag OFF for the whole test: the dedicated route
    # must NOT depend on any opt-in.
    Rails.configuration.x.forecast_v2.enabled = false
    Rails.configuration.x.forecast_v2.family_ids = Set.new.freeze

    sign_in @user
  end

  test "renders the V2 workspace with the feature flag OFF (no opt-in required)" do
    refute Forecasts::V2Flag.enabled_for?(family: @family, user: @user),
      "precondition: the V2 flag must be off so this proves the route is unflagged"

    get forecast_v2_url

    assert_response :success
    assert_inertia_component "Forecast/Workspace"

    %i[plan band selectedPeriod assumptionGroups issues freshness].each do |region|
      assert inertia.props.key?(region), "expected Inertia props to include #{region}"
    end
  end

  test "requires authentication" do
    sign_out

    get forecast_v2_url

    assert_redirected_to new_session_url
  end

  test "renders for a family with no connected forecast source data" do
    sign_in users(:empty)

    get forecast_v2_url

    assert_response :success
    assert_inertia_component "Forecast/Workspace"
    assert_kind_of Array, inertia.props.dig(:band, :period_keys)
    assert_includes %w[fresh stale recomputing failed superseded uncomputed],
      inertia.props.dig(:freshness, :state)
  end

  test "is idempotent: opening /forecast_v2 repeatedly creates exactly one plan" do
    assert_difference -> { Forecasts::Plan.where(family: @family).count }, 1 do
      get forecast_v2_url
      assert_response :success
    end

    assert_no_difference -> { Forecasts::Plan.where(family: @family).count } do
      3.times do
        get forecast_v2_url
        assert_response :success
      end
    end
  end

  test "the V2 route never instantiates the V1 Forecast::Workspace" do
    Forecast::Workspace.expects(:new).never

    get forecast_v2_url

    assert_response :success
    assert_inertia_component "Forecast/Workspace"
  end

  private
    def sign_out
      @user.sessions.each { |session| delete session_path(session) }
    end
end
