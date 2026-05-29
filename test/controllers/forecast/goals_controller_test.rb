require "test_helper"

class Forecast::GoalsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @family = @user.family
    @family.forecast_goals.delete_all
    @family.forecast_scenarios.delete_all
    @scenario = @family.forecast_scenarios.create!(name: "Base", status: "active")
    sign_in @user
  end

  # Regression: new/edit open in the "modal" turbo frame, so the response must
  # contain a <turbo-frame id="modal"> or Turbo renders "content missing".
  test "new renders the form inside the modal turbo frame" do
    get new_forecast_goal_url, headers: { "Turbo-Frame" => "modal" }

    assert_response :success
    # Exactly one modal frame: DS::Dialog already wraps in turbo-frame#modal, so a
    # manual wrapper would nest a duplicate id and Turbo renders "content missing".
    assert_select "turbo-frame#modal", count: 1
    assert_select "turbo-frame#modal form"
  end

  test "edit renders the form inside the modal turbo frame" do
    goal = @family.forecast_goals.create!(name: "Editable", goal_type: "minimum_cash_runway", target_duration_days: 90, blocking_behavior: "warn", status: "active")

    get edit_forecast_goal_url(goal), headers: { "Turbo-Frame" => "modal" }

    assert_response :success
    # Exactly one modal frame: DS::Dialog already wraps in turbo-frame#modal, so a
    # manual wrapper would nest a duplicate id and Turbo renders "content missing".
    assert_select "turbo-frame#modal", count: 1
    assert_select "turbo-frame#modal form"
  end

  def runway_params(overrides = {})
    {
      name: "Six month runway",
      goal_type: "minimum_cash_runway",
      target_duration_days: "180",
      blocking_behavior: "warn",
      status: "active"
    }.merge(overrides)
  end

  def amount_params(overrides = {})
    {
      name: "Emergency fund",
      goal_type: "minimum_cash_balance",
      target_amount: "10000",
      currency: "USD",
      blocking_behavior: "warn",
      status: "active"
    }.merge(overrides)
  end

  # --- index -----------------------------------------------------------------

  test "index lists only the current family's goals" do
    mine = @family.forecast_goals.create!(name: "Mine", goal_type: "minimum_cash_runway", target_duration_days: 90, blocking_behavior: "warn", status: "active")
    other = families(:empty).forecast_goals.create!(name: "Foreign", goal_type: "minimum_cash_runway", target_duration_days: 90, blocking_behavior: "warn", status: "active")

    get forecast_goals_path

    assert_response :success
    assert_select "##{dom_id(mine)}"
    assert_select "##{dom_id(other)}", count: 0
  end

  test "index renders an empty state when the family has no goals" do
    get forecast_goals_path

    assert_response :success
    assert_select "[data-testid=goals-empty-state]"
  end

  # --- create happy paths: each branch ---------------------------------------

  test "create persists a runway goal scoped to the current family" do
    assert_difference "@family.forecast_goals.count", 1 do
      post forecast_goals_path, params: { forecast_goal: runway_params }
    end

    assert_redirected_to forecast_goals_path
    goal = @family.forecast_goals.order(:created_at).last
    assert_equal "minimum_cash_runway", goal.goal_type
    assert_equal 180, goal.target_duration_days
    assert_equal @family.id, goal.family_id
  end

  test "create persists an amount goal" do
    assert_difference "@family.forecast_goals.count", 1 do
      post forecast_goals_path, params: { forecast_goal: amount_params }
    end

    assert_redirected_to forecast_goals_path
    goal = @family.forecast_goals.order(:created_at).last
    assert_equal "minimum_cash_balance", goal.goal_type
    assert_equal 10000, goal.target_amount.to_i
    assert_equal "USD", goal.currency
  end

  test "create persists a scenario-scoped goal" do
    assert_difference "@family.forecast_goals.count", 1 do
      post forecast_goals_path, params: { forecast_goal: amount_params(forecast_scenario_id: @scenario.id) }
    end

    goal = @family.forecast_goals.order(:created_at).last
    assert_equal @scenario.id, goal.forecast_scenario_id
  end

  # --- create validation / failure surfacing (422) ---------------------------

  test "create a runway goal without target_duration_days is rejected with a 422" do
    assert_no_difference "@family.forecast_goals.count" do
      post forecast_goals_path, params: { forecast_goal: runway_params(target_duration_days: "") }
    end

    assert_response :unprocessable_entity
    assert_select "form"
  end

  test "create an amount goal without target_amount is rejected with a 422" do
    assert_no_difference "@family.forecast_goals.count" do
      post forecast_goals_path, params: { forecast_goal: amount_params(target_amount: "") }
    end

    assert_response :unprocessable_entity
  end

  test "create an amount goal without currency is rejected with a 422" do
    assert_no_difference "@family.forecast_goals.count" do
      post forecast_goals_path, params: { forecast_goal: amount_params(currency: "") }
    end

    assert_response :unprocessable_entity
  end

  test "create with ends_on before starts_on is rejected with a 422" do
    assert_no_difference "@family.forecast_goals.count" do
      post forecast_goals_path, params: { forecast_goal: amount_params(
        starts_on: Date.current.to_s,
        ends_on: (Date.current - 5.days).to_s
      ) }
    end

    assert_response :unprocessable_entity
  end

  # --- evaluation badge (empty + populated) ----------------------------------

  test "a goal with no completed run renders the unknown evaluation badge" do
    goal = @family.forecast_goals.create!(name: "Runway", goal_type: "minimum_cash_runway", target_duration_days: 90, blocking_behavior: "warn", status: "active")

    get forecast_goals_path

    assert_response :success
    assert_select "##{dom_id(goal)}" do
      assert_select "*", text: I18n.t("forecasts.goals.evaluation_statuses.unknown")
    end
  end

  test "a goal with a matching evaluation renders its evaluation status badge" do
    goal = @family.forecast_goals.create!(name: "Runway", goal_type: "minimum_cash_runway", target_duration_days: 90, blocking_behavior: "warn", status: "active")
    seed_completed_run_with_goal_evaluation(goal, status: "warn")

    get forecast_goals_path

    assert_response :success
    assert_select "##{dom_id(goal)}" do
      assert_select "*", text: I18n.t("forecasts.goals.evaluation_statuses.warn")
    end
  end

  # --- create cannot set family_id via params --------------------------------

  test "create ignores a family_id passed in params" do
    other_family = families(:empty)

    post forecast_goals_path, params: { forecast_goal: runway_params(family_id: other_family.id) }

    assert_redirected_to forecast_goals_path
    goal = @family.forecast_goals.order(:created_at).last
    assert_equal @family.id, goal.family_id
    assert_nil other_family.forecast_goals.find_by(name: "Six month runway")
  end

  # --- authorization: foreign scenario rejected ------------------------------

  test "a foreign scenario id is rejected by the model with a 422" do
    foreign_scenario = families(:empty).forecast_scenarios.create!(name: "Foreign", status: "active")

    assert_no_difference "@family.forecast_goals.count" do
      post forecast_goals_path, params: { forecast_goal: amount_params(forecast_scenario_id: foreign_scenario.id) }
    end

    assert_response :unprocessable_entity
  end

  # --- update / destroy happy paths ------------------------------------------

  test "update changes attributes on the current family's goal" do
    goal = @family.forecast_goals.create!(name: "Old", goal_type: "minimum_cash_balance", target_amount: 5000, currency: "USD", blocking_behavior: "warn", status: "active")

    patch forecast_goal_path(goal), params: { forecast_goal: { name: "New", target_amount: "7500" } }

    assert_redirected_to forecast_goals_path
    goal.reload
    assert_equal "New", goal.name
    assert_equal 7500, goal.target_amount.to_i
  end

  test "update with invalid data re-renders the form with a 422" do
    goal = @family.forecast_goals.create!(name: "Valid", goal_type: "minimum_cash_balance", target_amount: 5000, currency: "USD", blocking_behavior: "warn", status: "active")

    patch forecast_goal_path(goal), params: { forecast_goal: { target_amount: "" } }

    assert_response :unprocessable_entity
    assert_equal 5000, goal.reload.target_amount.to_i
  end

  test "destroy removes the current family's goal" do
    goal = @family.forecast_goals.create!(name: "Delete me", goal_type: "minimum_cash_runway", target_duration_days: 90, blocking_behavior: "warn", status: "active")

    assert_difference "@family.forecast_goals.count", -1 do
      delete forecast_goal_path(goal)
    end

    assert_redirected_to forecast_goals_path
  end

  # --- authorization: cross-family ids are 404 -------------------------------

  test "edit on another family's goal is denied with a 404" do
    foreign = families(:empty).forecast_goals.create!(name: "Foreign", goal_type: "minimum_cash_runway", target_duration_days: 90, blocking_behavior: "warn", status: "active")

    get edit_forecast_goal_path(foreign)

    assert_response :not_found
  end

  test "update on another family's goal is denied with a 404" do
    foreign = families(:empty).forecast_goals.create!(name: "Foreign", goal_type: "minimum_cash_runway", target_duration_days: 90, blocking_behavior: "warn", status: "active")

    patch forecast_goal_path(foreign), params: { forecast_goal: { name: "Hijacked" } }

    assert_response :not_found
    assert_equal "Foreign", foreign.reload.name
  end

  test "destroy on another family's goal is denied with a 404" do
    foreign = families(:empty).forecast_goals.create!(name: "Foreign", goal_type: "minimum_cash_runway", target_duration_days: 90, blocking_behavior: "warn", status: "active")

    assert_no_difference "ForecastGoal.count" do
      delete forecast_goal_path(foreign)
    end

    assert_response :not_found
  end

  private
    # Build a minimal completed run group + run with one goal evaluation matching
    # the goal's engine key ("forecast_goal:<id>") so the badge test exercises the
    # real workspace join path. Status is forced "completed" after building the
    # children so the immutable-output guards do not block the inserts.
    def seed_completed_run_with_goal_evaluation(goal, status:)
      group = @family.forecast_run_groups.create!(
        name: "Test run",
        run_type: "manual",
        status: "pending",
        currency: "USD",
        horizon_start_on: Date.current,
        horizon_end_on: Date.current + 36.months,
        daily_until_on: Date.current + 90.days
      )

      run = group.forecast_runs.create!(
        family: @family,
        scenario_stack_key: Forecast::Workspace::BASELINE_STACK_KEY,
        scenario_stack_snapshot: { "scenario_ids" => [] },
        status: "pending",
        feasibility_status: "warn",
        currency: "USD"
      )

      run.forecast_goal_evaluations.create!(
        forecast_goal: goal,
        goal_key: "forecast_goal:#{goal.id}",
        scenario_stack_key: Forecast::Workspace::BASELINE_STACK_KEY,
        status: status,
        currency: "USD",
        goal_snapshot: { "id" => goal.id, "goal_type" => goal.goal_type }
      )

      # Promote to completed once children exist. Mark the run completed with the
      # input snapshot the model requires, then the group.
      run.update_columns(status: "completed")
      group.update_columns(status: "completed")
    end
end
