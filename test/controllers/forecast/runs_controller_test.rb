require "test_helper"

class Forecast::RunsControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper
  include ForecastRunGroupTestHelper

  setup do
    @user = users(:family_admin)
    @family = @user.family
    @family.forecast_run_groups.delete_all
    sign_in @user
  end

  # --- create: enqueues the async job, never runs the Runner inline ----------

  test "create enqueues ForecastGenerationJob with the baseline stack args" do
    assert_enqueued_with(
      job: ForecastGenerationJob,
      args: [ { family: @family, user: @user, name: I18n.t("forecasts.runs.default_name", date: I18n.l(Date.current, format: :long)) } ]
    ) do
      post forecast_runs_path
    end

    assert_redirected_to forecast_path
    assert_equal I18n.t("forecasts.runs.enqueued"), flash[:notice]
  end

  test "create does not run the Runner inline" do
    Forecast::Runner.any_instance.expects(:call).never

    assert_enqueued_jobs 1, only: ForecastGenerationJob do
      post forecast_runs_path
    end
  end

  # --- empty/edge: a family with no accounts/budgets still enqueues -----------

  test "create still enqueues for a family with zero accounts and budgets" do
    # The empty family has no accounts/budgets/scenarios; generation must still
    # be allowed (the resulting run simply has nothing to project).
    empty_user = users(:empty)
    empty_user.family.forecast_run_groups.delete_all
    sign_in empty_user

    assert_enqueued_jobs 1, only: ForecastGenerationJob do
      post forecast_runs_path
    end

    assert_redirected_to forecast_path
  end

  # --- guard: block a second generation while one is in flight ---------------

  test "create is blocked and enqueues nothing while a generation is in flight" do
    @family.forecast_run_groups.create!(
      user: @user,
      name: "In flight",
      run_type: "manual",
      status: "running",
      currency: @family.currency,
      horizon_start_on: Date.current,
      horizon_end_on: 36.months.from_now.to_date,
      daily_until_on: 90.days.from_now.to_date
    )

    assert_no_enqueued_jobs only: ForecastGenerationJob do
      post forecast_runs_path
    end

    assert_redirected_to forecast_path
    assert_equal I18n.t("forecasts.runs.already_running"), flash[:alert]
  end

  test "create is blocked when a pending generation already exists" do
    @family.forecast_run_groups.create!(
      user: @user,
      name: "Pending",
      run_type: "manual",
      status: "pending",
      currency: @family.currency,
      horizon_start_on: Date.current,
      horizon_end_on: 36.months.from_now.to_date,
      daily_until_on: 90.days.from_now.to_date
    )

    assert_no_enqueued_jobs only: ForecastGenerationJob do
      post forecast_runs_path
    end

    assert_redirected_to forecast_path
  end

  # --- status: live status JSON scoped to the current family -----------------

  test "status returns live status json for the current family's group" do
    group = build_completed_run_group(family: @family, user: @user)

    get status_forecast_run_path(group), as: :json

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal group.id, body["id"]
    assert_equal "completed", body["status"]
    assert_equal true, body["done"]
  end

  test "status reports a running group as not done" do
    group = @family.forecast_run_groups.create!(
      user: @user,
      name: "In flight",
      run_type: "manual",
      status: "running",
      currency: @family.currency,
      horizon_start_on: Date.current,
      horizon_end_on: 36.months.from_now.to_date,
      daily_until_on: 90.days.from_now.to_date
    )

    get status_forecast_run_path(group), as: :json

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal "running", body["status"]
    assert_equal false, body["done"]
  end

  # --- authorization: cross-family ids are 404 -------------------------------

  test "status for another family's run group is denied with a 404" do
    other_family = families(:empty)
    other_group = build_completed_run_group(family: other_family, user: users(:empty))

    get status_forecast_run_path(other_group), as: :json

    # Family-scoped lookup raises RecordNotFound, which the app renders as 404.
    assert_response :not_found
  end

  test "create only scopes generation to the current family" do
    # A signed-in member of dylan_family can never enqueue against empty family;
    # the job always carries Current.family/Current.user.
    assert_enqueued_with(
      job: ForecastGenerationJob,
      args: [ { family: @family, user: @user, name: I18n.t("forecasts.runs.default_name", date: I18n.l(Date.current, format: :long)) } ]
    ) do
      post forecast_runs_path
    end
  end
end
