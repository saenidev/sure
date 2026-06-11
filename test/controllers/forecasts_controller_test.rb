require "test_helper"

class ForecastsControllerTest < ActionDispatch::IntegrationTest
  include ForecastRunGroupTestHelper

  setup do
    @user = users(:family_admin)
    @family = @user.family
    @family.forecast_run_groups.delete_all
    @family.forecast_events.delete_all
    @family.forecast_scenarios.delete_all
    @family.forecast_goals.delete_all
    sign_in @user
  end

  # --- lazy tab loading (V1 #tab endpoint, routable until the phase-9 cutover) -

  test "tab endpoint frame targets _top so panel forms drive full-page navigation" do
    build_completed_run_group(family: @family, user: @user, runs: 2)

    get forecast_tab_url(tab_id: "inputs")

    assert_response :success
    assert_select "turbo-frame#forecast_tab_inputs[target='_top']"
  end

  test "inputs tab does not load projection month rows" do
    build_run_group_with_series(family: @family, user: @user, days: 0, months: 36)

    assert_queries_count(matcher: /forecast_months/, max: 0) do
      get forecast_tab_url(tab_id: "inputs")
    end

    assert_response :success
    assert_select "turbo-frame#forecast_tab_inputs"
  end

  test "tab endpoint renders a single tab body inside its matching Turbo Frame" do
    build_completed_run_group(family: @family, user: @user, runs: 2)

    get forecast_tab_url(tab_id: "what_if")

    assert_response :success
    assert_select "turbo-frame#forecast_tab_what_if" do
      assert_select "[data-testid=forecast-comparison-table] tbody tr", count: 2
    end
  end

  test "tab endpoint 404s for an unknown tab id" do
    build_completed_run_group(family: @family, user: @user, runs: 1)

    get forecast_tab_url(tab_id: "bogus")

    assert_response :not_found
  end

  test "tab endpoint never renders another family's run (cross-family denial)" do
    other_family = families(:empty)
    other_family.forecast_run_groups.delete_all
    build_completed_run_group(family: other_family, user: users(:empty), runs: 2)

    # The current family has no run of its own, so the what-if body must show
    # its own empty state, never the other family's stacks.
    get forecast_tab_url(tab_id: "what_if")

    assert_response :success
    assert_select "turbo-frame#forecast_tab_what_if"
    assert_select "[data-testid=forecast-comparison-table]", count: 0
    assert_select "#forecast-comparison-empty-title"
  end

  private
    # Counts queries matching a pattern issued during the block and asserts the
    # count stays within bound, guarding against N+1 over forecast runs.
    def assert_queries_count(matcher:, max:)
      queries = []
      callback = ->(_name, _start, _finish, _id, payload) do
        sql = payload[:sql]
        queries << sql if sql&.match?(matcher) && !payload[:name].to_s.include?("SCHEMA")
      end

      ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { yield }

      assert queries.size <= max,
        "expected at most #{max} queries matching #{matcher.inspect}, got #{queries.size}:\n#{queries.join("\n")}"
    end
end

class Forecast::BaseControllerAuthorizationTest < ActiveSupport::TestCase
  include ForecastRunGroupTestHelper

  setup do
    @family = families(:dylan_family)
    @other_family = families(:empty)
    @other_family.forecast_run_groups.delete_all
  end

  test "find_run_group_scoped raises RecordNotFound for another family's run group" do
    other_group = build_completed_run_group(family: @other_family, user: users(:empty))

    controller = Forecast::BaseController.new
    controller.instance_variable_set(:@family, @family)

    assert_raises ActiveRecord::RecordNotFound do
      controller.send(:find_run_group_scoped, other_group.id)
    end
  end

  test "find_run_group_scoped returns the current family's own run group" do
    own_group = build_completed_run_group(family: @family, user: users(:family_admin))

    controller = Forecast::BaseController.new
    controller.instance_variable_set(:@family, @family)

    assert_equal own_group, controller.send(:find_run_group_scoped, own_group.id)
  end
end
