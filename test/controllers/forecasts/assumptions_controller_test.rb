# frozen_string_literal: true

require "test_helper"

class Forecasts::AssumptionsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @user = users(:family_admin)
    @family = @user.family
    @plan = Forecasts::WorkspaceLoader.new(family: @family, today: Date.current).load.plan
    @assumption = @plan.forecast_assumptions.create!(
      family: @family, kind: "salary", name: "Salary", status: :active,
      amount: 5200, currency: "USD",
      params: { "frequency" => "monthly", "growth_policy" => "flat" }
    )
  end

  test "edit renders the drawer in the modal frame" do
    get edit_forecasts_assumption_path(@assumption), headers: { "Turbo-Frame" => "modal" }
    assert_response :success
    assert_select "turbo-frame#modal", count: 1
    assert_select "form[action=?]", forecasts_assumption_path(@assumption)
    assert_select "input[name=?]", "assumption[expected_lock_version]"
  end

  test "edit is family-scoped" do
    sign_in users(:empty)
    get edit_forecasts_assumption_path(@assumption)
    assert_response :not_found
  end
end
