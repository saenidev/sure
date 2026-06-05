require "test_helper"
require "inertia_rails/minitest"

# THROWAWAY viability spike coverage (Forecast V2 / slice A2). Proves the
# authenticated /forecast_v2_spike route renders an Inertia page with typed,
# read-model-shaped props that never touch the V1 Forecast::Workspace / engine /
# run-group tables. Delete with the ForecastV2SpikeController and its Inertia
# page when the spike is folded into Phase 2 or removed.
class ForecastV2SpikeControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
  end

  test "redirects to sign in when signed out" do
    get forecast_v2_spike_path

    assert_redirected_to new_session_url
  end

  test "renders the Forecast/Spike Inertia component for an authenticated user" do
    sign_in @user
    get forecast_v2_spike_path

    assert_response :success
    assert_inertia_component "Forecast/Spike"
  end

  test "exposes only typed read-model-shaped props" do
    sign_in @user
    get forecast_v2_spike_path

    assert_response :success

    %i[plan currentPeriodKey periodKeys series metrics privacy freshness].each do |key|
      assert inertia.props.key?(key), "expected Inertia props to include #{key}"
    end
  end

  test "plan prop carries a label and currency context" do
    sign_in @user
    get forecast_v2_spike_path

    plan = inertia.props[:plan]
    assert plan[:label].present?, "expected plan.label to be present"
    assert plan[:currency].present?, "expected plan.currency to be present"
  end

  test "period props are ordered and consistent with the metric series" do
    sign_in @user
    get forecast_v2_spike_path

    period_keys = inertia.props[:periodKeys]
    series = inertia.props[:series]

    assert period_keys.is_a?(Array)
    assert_equal period_keys.sort, period_keys, "expected period keys to be chronologically ordered"
    assert_includes period_keys, inertia.props[:currentPeriodKey]
    assert_equal period_keys, series.map { |point| point[:periodKey] },
      "expected one series point per period key, in order"
  end

  test "each series point exposes decimal-string net worth and cash metrics" do
    sign_in @user
    get forecast_v2_spike_path

    series = inertia.props[:series]
    assert series.any?

    series.each do |point|
      assert point.key?(:netWorth), "expected series point to include netWorth"
      assert point.key?(:cash), "expected series point to include cash"
      assert_kind_of String, point[:netWorth]
      assert_kind_of String, point[:cash]
      assert_match(/\A-?\d+\.\d{2}\z/, point[:netWorth])
      assert_match(/\A-?\d+\.\d{2}\z/, point[:cash])
    end
  end

  test "privacy and freshness props carry typed state" do
    sign_in @user
    get forecast_v2_spike_path

    assert_includes [ true, false ], inertia.props[:privacy][:enabled]
    assert_includes %w[fresh stale recomputing], inertia.props[:freshness][:state]
  end

  test "does not read or mutate any V1 forecast workspace or run groups" do
    sign_in @user

    Forecast::Workspace.expects(:new).never
    assert_no_difference -> { @user.family.forecast_run_groups.count } do
      get forecast_v2_spike_path
    end

    assert_response :success
  end
end
