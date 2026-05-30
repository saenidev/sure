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
    assert_difference "@family.forecast_run_groups.pending.count", 1 do
      post forecast_runs_path
    end

    group = @family.forecast_run_groups.order(:created_at).last
    assert_enqueued_with(
      job: ForecastGenerationJob,
      args: [ { run_group: group, scenario_stacks: [ [] ] } ]
    )
    assert_redirected_to forecast_path
    assert_equal I18n.t("forecasts.runs.enqueued"), flash[:notice]
  end

  test "create does not run the Runner inline" do
    Forecast::Runner.any_instance.expects(:call).never

    assert_enqueued_jobs 1, only: ForecastGenerationJob do
      post forecast_runs_path
    end
  end

  test "create reserves a pending group before enqueue so duplicate submits are blocked" do
    post forecast_runs_path
    assert_redirected_to forecast_path

    assert_no_enqueued_jobs only: ForecastGenerationJob do
      post forecast_runs_path
    end

    assert_redirected_to forecast_path
    assert_equal I18n.t("forecasts.runs.already_running"), flash[:alert]
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
    post forecast_runs_path

    group = @family.forecast_run_groups.order(:created_at).last
    assert_equal @family.id, group.family_id
    assert_equal @user.id, group.user_id
    assert_enqueued_with(job: ForecastGenerationJob, args: [ { run_group: group, scenario_stacks: [ [] ] } ])
  end

  # --- comparison: scenario_stacks param -------------------------------------

  test "create enqueues the comparison job with exactly the submitted stacks plus baseline" do
    @family.forecast_scenarios.delete_all
    scenario_a = @family.forecast_scenarios.create!(name: "A", status: "active")
    scenario_b = @family.forecast_scenarios.create!(name: "B", status: "active")

    expected_name = I18n.t("forecasts.runs.default_name", date: I18n.l(Date.current, format: :long))

    post forecast_runs_path, params: {
      scenario_stacks: {
        "0" => { scenario_ids: [ scenario_a.id ] },
        "1" => { scenario_ids: [ scenario_a.id, scenario_b.id ] }
      }
    }

    group = @family.forecast_run_groups.order(:created_at).last
    assert_equal expected_name, group.name
    assert_enqueued_with(
      job: ForecastGenerationJob,
      args: [ { run_group: group, scenario_stacks: [ [], [ scenario_a.id ], [ scenario_a.id, scenario_b.id ] ] } ]
    )
    assert_redirected_to forecast_path
  end

  test "empty scenario_stacks submission defaults to baseline-only" do
    post forecast_runs_path, params: { scenario_stacks: { "0" => { scenario_ids: [] } } }

    group = @family.forecast_run_groups.order(:created_at).last
    assert_enqueued_with(job: ForecastGenerationJob, args: [ { run_group: group, scenario_stacks: [ [] ] } ])
  end

  # --- validation / authorization: foreign or over-cap stacks reject ----------

  test "a stack containing a foreign scenario id is rejected with 422 and enqueues nothing" do
    foreign = families(:empty).forecast_scenarios.create!(name: "Foreign", status: "active")
    mine = @family.forecast_scenarios.create!(name: "Mine", status: "active")

    assert_no_enqueued_jobs only: ForecastGenerationJob do
      post forecast_runs_path, params: {
        scenario_stacks: { "0" => { scenario_ids: [ mine.id, foreign.id ] } }
      }
    end

    assert_response :unprocessable_entity
  end

  test "an unknown scenario id is rejected with 422 and enqueues nothing" do
    assert_no_enqueued_jobs only: ForecastGenerationJob do
      post forecast_runs_path, params: {
        scenario_stacks: { "0" => { scenario_ids: [ "00000000-0000-0000-0000-000000000000" ] } }
      }
    end

    assert_response :unprocessable_entity
  end

  test "a disabled scenario id is rejected with 422 and enqueues nothing" do
    scenario = @family.forecast_scenarios.create!(name: "Disabled", status: "disabled")

    assert_no_enqueued_jobs only: ForecastGenerationJob do
      post forecast_runs_path, params: {
        scenario_stacks: { "0" => { scenario_ids: [ scenario.id ] } }
      }
    end

    assert_response :unprocessable_entity
  end

  test "an archived scenario id is rejected with 422 and enqueues nothing" do
    scenario = @family.forecast_scenarios.create!(name: "Archived", status: "archived")

    assert_no_enqueued_jobs only: ForecastGenerationJob do
      post forecast_runs_path, params: {
        scenario_stacks: { "0" => { scenario_ids: [ scenario.id ] } }
      }
    end

    assert_response :unprocessable_entity
  end

  test "more stacks than the cap is rejected with 422 and enqueues nothing" do
    scenarios = Array.new(Forecast::RunsController::MAX_SCENARIO_STACKS + 1) do |i|
      @family.forecast_scenarios.create!(name: "S#{i}", status: "active")
    end

    # Each stack carries a distinct scenario so they do not dedupe away; with
    # baseline added this exceeds the cap.
    stacks = scenarios.each_with_index.to_h { |scenario, i| [ i.to_s, { scenario_ids: [ scenario.id ] } ] }

    assert_no_enqueued_jobs only: ForecastGenerationJob do
      post forecast_runs_path, params: { scenario_stacks: stacks }
    end

    assert_response :unprocessable_entity
  end

  test "comparison create is blocked while a generation is in flight" do
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
    scenario = @family.forecast_scenarios.create!(name: "A", status: "active")

    assert_no_enqueued_jobs only: ForecastGenerationJob do
      post forecast_runs_path, params: {
        scenario_stacks: { "0" => { scenario_ids: [ scenario.id ] } }
      }
    end

    assert_redirected_to forecast_path
  end
end
