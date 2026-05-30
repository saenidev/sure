require "test_helper"

class Forecast::TemplatesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @family = @user.family
    @family.forecast_scenarios.delete_all
    sign_in @user
  end

  # --- index -----------------------------------------------------------------

  test "index renders the frozen template catalog as apply cards" do
    get forecast_templates_path

    assert_response :success
    # One card per catalog template, each with an apply form and hidden key.
    assert_select "[data-testid=forecast-template-card]", count: Forecast::ScenarioTemplate.all.size
    assert_select "input[type=hidden][name=template_key][value=country_move]"
    assert_select "input[type=hidden][name=template_key][value=major_purchase]"
  end

  test "index scenario manager trigger is a GET link, not a POST form" do
    get forecast_templates_path

    assert_response :success
    assert_select "a[href=?]", forecast_scenarios_path
    assert_select "form[action=?]", forecast_scenarios_path, false
  end

  # --- create (happy path) ---------------------------------------------------

  test "applying a template creates a disabled scenario with events scoped to the family" do
    assert_difference "@family.forecast_scenarios.count", 1 do
      post forecast_templates_path, params: {
        template_key: "country_move",
        template_params: {
          move_on: "2026-09-01",
          moving_cost: "5000",
          monthly_cost_delta: "300"
        }
      }
    end

    assert_redirected_to forecast_scenarios_path
    assert flash[:notice].present?

    scenario = @family.forecast_scenarios.order(:created_at).last
    assert_equal @family.id, scenario.family_id
    assert_equal "disabled", scenario.status
    assert_equal "manual", scenario.approval_status
    assert_equal @user.id, scenario.created_by_user_id

    # Template provenance recorded in source_metadata.
    assert_equal "template", scenario.source_metadata["source"]
    assert_equal "country_move", scenario.source_metadata["template_key"]
    assert_equal "2026-09-01", scenario.source_metadata.dig("params", "move_on")

    # Children are created and family-scoped (relocation cost + monthly delta).
    assert_equal 2, scenario.forecast_events.count
    scenario.forecast_events.each do |event|
      assert_equal @family.id, event.family_id
    end
  end

  test "applying a template that ships goals creates them scoped to the family" do
    assert_difference "@family.forecast_goals.count", 1 do
      post forecast_templates_path, params: {
        template_key: "income_loss",
        template_params: {
          starts_on: "2026-09-01",
          lost_monthly_income: "4000",
          runway_floor_days: "120"
        }
      }
    end

    scenario = @family.forecast_scenarios.order(:created_at).last
    goal = scenario.forecast_goals.first
    assert_equal @family.id, goal.family_id
    assert_equal "minimum_cash_runway", goal.goal_type
    assert_equal 120, goal.target_duration_days
  end

  # --- create (invalid params -> 422, no write) ------------------------------

  test "invalid params re-render the browse surface at 422 and create nothing" do
    assert_no_difference [ "@family.forecast_scenarios.count", "@family.forecast_events.count" ] do
      post forecast_templates_path, params: {
        template_key: "country_move",
        template_params: {
          # missing required move_on; negative moving_cost
          moving_cost: "-100"
        }
      }
    end

    assert_response :unprocessable_entity
    assert_select "[data-testid=forecast-templates-list]"
    # The offending form repopulates the rejected value.
    assert_select "input[name='template_params[moving_cost]'][value='-100']"
  end

  test "an unknown template key re-renders at 422 and creates nothing" do
    assert_no_difference "@family.forecast_scenarios.count" do
      post forecast_templates_path, params: {
        template_key: "not_a_real_template",
        template_params: {}
      }
    end

    assert_response :unprocessable_entity
    assert_select "[data-testid=forecast-templates-list]"
  end

  # --- authorization: a user only ever creates into their OWN family ---------

  test "a params-supplied family is ignored; the scenario belongs to the current family" do
    other_family = families(:empty)

    assert_no_difference "other_family.forecast_scenarios.count" do
      post forecast_templates_path, params: {
        template_key: "major_purchase",
        family_id: other_family.id,
        family: { id: other_family.id },
        template_params: {
          purchase_on: "2026-10-01",
          purchase_amount: "20000"
        }
      }
    end

    assert_redirected_to forecast_scenarios_path
    scenario = @family.forecast_scenarios.order(:created_at).last
    assert_equal @family.id, scenario.family_id
    refute_equal other_family.id, scenario.family_id
  end

  test "applying is deterministic: same key + params yields identical planning attributes" do
    params = {
      template_key: "major_purchase",
      template_params: { purchase_on: "2026-10-01", purchase_amount: "20000" }
    }

    post forecast_templates_path, params: params
    first = @family.forecast_scenarios.order(:created_at).last

    post forecast_templates_path, params: params
    second = @family.forecast_scenarios.order(:created_at).last

    refute_equal first.id, second.id
    assert_equal first.source_metadata["params"], second.source_metadata["params"]
    assert_equal first.forecast_events.map(&:amount), second.forecast_events.map(&:amount)
  end
end
