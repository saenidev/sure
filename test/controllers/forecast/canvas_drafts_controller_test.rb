require "test_helper"

class Forecast::CanvasDraftsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @family = @user.family
    @family.forecast_events.delete_all
    @family.forecast_scenarios.delete_all
    @scenario = @family.forecast_scenarios.create!(name: "Move", status: "active", approval_status: "manual")
    sign_in @user
  end

  test "create persists a canvas-authored forecast event" do
    assert_difference "@family.forecast_events.count", 1 do
      post forecast_canvas_drafts_path(format: :json), params: {
        forecast_event: {
          name: "Relocation cost",
          effect_type: "expense",
          amount: "5000",
          currency: @family.currency,
          starts_on: Date.current.to_s,
          status: "planned",
          probability_weight: "1.0",
          forecast_scenario_id: @scenario.id
        }
      }
    end

    assert_response :created
    event = @family.forecast_events.order(:created_at).last
    assert_equal "Relocation cost", event.name
    assert_equal @scenario.id, event.forecast_scenario_id
    assert_equal "additive", event.behavior
  end

  test "create rejects invalid draft without persisting" do
    assert_no_difference "@family.forecast_events.count" do
      post forecast_canvas_drafts_path(format: :json), params: {
        forecast_event: {
          name: "",
          effect_type: "expense",
          amount: "",
          currency: @family.currency,
          starts_on: Date.current.to_s,
          status: "planned"
        }
      }
    end

    assert_response :unprocessable_entity
    body = JSON.parse(response.body)
    assert body["errors"].present?
  end

  test "create rejects a foreign scenario id" do
    foreign = families(:empty).forecast_scenarios.create!(name: "Foreign", status: "active", approval_status: "manual")

    assert_no_difference "@family.forecast_events.count" do
      post forecast_canvas_drafts_path(format: :json), params: {
        forecast_event: {
          name: "Invalid",
          effect_type: "income",
          amount: "10",
          currency: @family.currency,
          starts_on: Date.current.to_s,
          status: "planned",
          forecast_scenario_id: foreign.id
        }
      }
    end
    assert_response :not_found
  end

  test "fork duplicates an existing scenario for the canvas" do
    @scenario.forecast_events.create!(
      family: @family,
      name: "Rent increase",
      effect_type: "expense",
      behavior: "additive",
      amount: 300,
      currency: @family.currency,
      starts_on: Date.current,
      status: "planned"
    )

    assert_difference "@family.forecast_scenarios.count", 1 do
      post forecast_canvas_forks_path(format: :json), params: {
        source_scenario_id: @scenario.id,
        name: "Move fork"
      }
    end

    assert_response :created
    copy = @family.forecast_scenarios.order(:created_at).last
    assert_equal "Move fork", copy.name
    assert_equal @scenario.id, copy.parent_scenario_id
    assert_equal 1, copy.forecast_events.count
  end

  test "fork creates a new blank scenario from baseline" do
    assert_difference "@family.forecast_scenarios.count", 1 do
      post forecast_canvas_forks_path(format: :json), params: {
        source: "baseline",
        name: "Baseline fork"
      }
    end

    assert_response :created
    scenario = @family.forecast_scenarios.order(:created_at).last
    assert_equal "Baseline fork", scenario.name
    assert_equal "active", scenario.status
    assert_nil scenario.parent_scenario_id
  end
end
