require "test_helper"

class ForecastsControllerTest < ActionDispatch::IntegrationTest
  include ForecastRunGroupTestHelper

  setup do
    @user = users(:family_admin)
    @family = @user.family
    @family.forecast_run_groups.delete_all
    @family.forecast_scenarios.delete_all
    @family.forecast_events.delete_all
    @family.forecast_goals.delete_all
    sign_in @user
  end

  test "renders for users without preview access" do
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => false))

    get forecast_url

    assert_response :success
    assert_select "h1", text: /Forecast/i
  end

  test "renders for users with preview access" do
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => true))

    get forecast_url

    assert_response :success
    assert_select "h1", text: /Forecast/i
  end

  test "renders a sidebar nav link to the forecast page" do
    get forecast_url

    assert_response :success
    assert_select "a[href=?]", forecast_path
  end

  test "renders onboarding empty state when there is no planning data and no run" do
    get forecast_url

    assert_response :success
    assert_select "#forecast-empty-state-title", text: I18n.t("forecasts.empty_state.onboarding.title")
    assert_select "button", text: I18n.t("forecasts.show.generate")
    assert_select "button", text: I18n.t("forecasts.show.set_up_scenarios")
  end

  test "renders ready state when planning data exists but no completed run" do
    @family.forecast_scenarios.create!(name: "Job change", status: "active", approval_status: "manual")

    get forecast_url

    assert_response :success
    assert_select "#forecast-empty-state-title", text: I18n.t("forecasts.empty_state.ready.title")
  end

  test "renders run summary header and tab scaffolding when latest run completed" do
    build_completed_run_group(family: @family, user: @user, runs: 2)

    get forecast_url

    assert_response :success
    assert_select "section[aria-label=?]", I18n.t("forecasts.run_summary_header.title")
    Forecast::Workspace::TAB_IDS.each do |tab_id|
      assert_select "button[data-id=?]", tab_id
    end
  end

  test "surfaces failure alert with error message when latest run failed" do
    build_failed_run_group(family: @family, user: @user, error_message: "MoneyConverter::MissingRate: USD->EUR")

    get forecast_url

    assert_response :success
    assert_select "[role=alert]"
    assert_select "[role=alert]", text: /MoneyConverter::MissingRate: USD->EUR/
  end

  test "does not render another family's most recent global run group" do
    other_family = families(:empty)
    other_family.forecast_run_groups.delete_all
    build_completed_run_group(family: other_family, user: users(:empty), created_at: 1.minute.ago)

    get forecast_url

    assert_response :success
    # Current family has nothing, so it must see its own onboarding state, not
    # the other family's completed run.
    assert_select "#forecast-empty-state-title", text: I18n.t("forecasts.empty_state.onboarding.title")
    assert_select "section[aria-label='#{I18n.t("forecasts.run_summary_header.title")}']", count: 0
  end

  test "avoids N+1 queries while eager-loading forecast runs in run state" do
    build_completed_run_group(family: @family, user: @user, runs: 3)

    # Warm caches (sessions, current setup) so the assertion focuses on the
    # forecast read path.
    get forecast_url
    assert_response :success

    assert_queries_count(matcher: /forecast_runs/, max: 1) do
      get forecast_url
    end
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
