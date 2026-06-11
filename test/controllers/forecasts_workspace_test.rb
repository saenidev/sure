# frozen_string_literal: true

require "test_helper"

class ForecastsWorkspaceTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @user = users(:family_admin)
  end

  test "GET /forecast bootstraps a plan and renders the workspace" do
    assert_difference -> { @user.family.forecast_plans.count }, 1 do
      get forecast_path
    end
    assert_response :success
    assert_select "#forecast_workspace"
    assert_select "#forecast-island", count: 1
    assert_select "#forecast_assumption_rail"
    assert_select "[data-controller=forecast-chart]"
  end

  test "GET /forecast never renders V1 generate affordances" do
    get forecast_path
    assert_response :success
    assert_select "form[action=?]", "/forecast/runs", count: 0
  end

  test "GET /forecast runs no engine work when the cache is current" do
    get forecast_path # first load computes
    plan = @user.family.forecast_plans.first
    cache_id = plan.forecast_projection_caches.first.id

    get forecast_path
    assert_response :success
    assert_equal cache_id, plan.reload.forecast_projection_caches.first.id
  end
end
