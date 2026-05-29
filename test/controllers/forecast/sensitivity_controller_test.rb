require "test_helper"

class Forecast::SensitivityControllerTest < ActionDispatch::IntegrationTest
  include ForecastRunGroupTestHelper

  setup do
    @user = users(:family_admin)
    @family = @user.family
    @family.forecast_run_groups.delete_all
    sign_in @user
  end

  # --- show (happy path) -----------------------------------------------------

  test "renders the sensitivity panel with a perturbation row per default-catalog entry for a completed baseline run" do
    build_completed_run_group(family: @family, user: @user, runs: 1)

    get forecast_sensitivity_path

    assert_response :success
    # The lazy frame target wraps the rendered analysis.
    assert_select "turbo-frame#forecast_sensitivity"
    assert_select "[data-testid=forecast-sensitivity-table]"
    Forecast::SensitivityAnalyzer::DEFAULT_CATALOG.each do |perturbation|
      assert_select "[data-testid=forecast-sensitivity-row-#{perturbation.key}]"
    end
  end

  # --- show (no completed run -> empty state, no analyzer run) ----------------

  test "renders the no-rows empty state and never runs the analyzer when there is no completed run" do
    # A totally failed group has no completed baseline run to analyze.
    build_failed_run_group(family: @family, user: @user, error_message: "boom")

    # The N+1 engine runs must not happen when there is nothing to analyze.
    Forecast::SensitivityAnalyzer.any_instance.expects(:call).never

    get forecast_sensitivity_path

    assert_response :success
    assert_select "[data-testid=forecast-sensitivity-no-rows]"
    assert_select "[data-testid=forecast-sensitivity-table]", count: 0
  end

  # --- cross-family scoping --------------------------------------------------

  test "analyzes only the current family's run, never another family's" do
    # Another family owns the only (most recent, global) completed run group.
    other_family = families(:empty)
    other_family.forecast_run_groups.delete_all
    build_completed_run_group(family: other_family, user: users(:empty))

    get forecast_sensitivity_path

    # The current family has no completed run, so the panel falls back to the
    # empty state rather than analyzing the other family's run.
    assert_response :success
    assert_select "[data-testid=forecast-sensitivity-no-rows]"
    assert_select "[data-testid=forecast-sensitivity-table]", count: 0
  end
end
