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

  test "create persists recurring categorized event details" do
    assert_difference "@family.forecast_events.count", 1 do
      post forecast_canvas_drafts_path(format: :json), params: {
        forecast_event: {
          name: "School tuition",
          effect_type: "expense",
          amount: "1200",
          currency: @family.currency,
          starts_on: Date.current.to_s,
          ends_on: (Date.current + 1.year).to_s,
          recurring: "1",
          recurrence_rule: {
            frequency: "monthly",
            interval: "2",
            day_of_month: "15"
          },
          category_id: categories(:food_and_drink).id,
          status: "accepted",
          probability_weight: "0.7",
          description: "Private school scenario"
        }
      }
    end

    assert_response :created
    event = @family.forecast_events.order(:created_at).last
    assert_equal categories(:food_and_drink).id, event.category_id
    assert_equal({ "frequency" => "monthly", "interval" => 2, "day_of_month" => 15 }, event.recurrence_rule)
    assert_equal Date.current + 1.year, event.ends_on
    assert_equal BigDecimal("0.7"), event.probability_weight
    assert_equal "Private school scenario", event.description
    assert_equal "accepted", event.status
  end

  test "create persists transfer account fields" do
    assert_difference "@family.forecast_events.count", 1 do
      post forecast_canvas_drafts_path(format: :json), params: {
        forecast_event: {
          name: "Move cash",
          effect_type: "transfer",
          amount: "250",
          currency: @family.currency,
          starts_on: Date.current.to_s,
          status: "planned",
          account_id: accounts(:depository).id,
          destination_account_id: accounts(:investment).id
        }
      }
    end

    assert_response :created
    event = @family.forecast_events.order(:created_at).last
    assert_equal accounts(:depository).id, event.account_id
    assert_equal accounts(:investment).id, event.destination_account_id
  end

  test "create can target a new canvas scenario" do
    assert_difference "@family.forecast_scenarios.count", 1 do
      assert_difference "@family.forecast_events.count", 1 do
        post forecast_canvas_drafts_path(format: :json), params: {
          forecast_event: {
            name: "Relocation cost",
            effect_type: "expense",
            amount: "5000",
            currency: @family.currency,
            starts_on: Date.current.to_s,
            status: "planned",
            scenario_target: "__new__",
            new_scenario_name: "Canvas move"
          }
        }
      end
    end

    assert_response :created
    scenario = @family.forecast_scenarios.order(:created_at).last
    event = @family.forecast_events.order(:created_at).last
    assert_equal "Canvas move", scenario.name
    assert_equal "active", scenario.status
    assert_equal "manual", scenario.approval_status
    assert_equal scenario.id, event.forecast_scenario_id
    assert_equal scenario.id, JSON.parse(response.body).dig("scenario", "id")
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

  test "fork combines selected stack scenarios into a disabled scenario copy" do
    second = @family.forecast_scenarios.create!(name: "Sabbatical", status: "active", approval_status: "manual")
    second.forecast_events.create!(
      family: @family,
      name: "Travel",
      effect_type: "expense",
      behavior: "additive",
      amount: 200,
      currency: @family.currency,
      starts_on: Date.current,
      status: "planned"
    )
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
        source_scenario_ids: [ @scenario.id, second.id ],
        name: "Stack fork"
      }
    end

    assert_response :created
    copy = @family.forecast_scenarios.order(:created_at).last
    assert_equal "Stack fork", copy.name
    assert_equal "disabled", copy.status
    assert_equal 2, copy.forecast_events.count
    assert_equal [ @scenario.id, second.id ].map(&:to_s).sort,
      copy.source_metadata.dig("canvas_fork", "source_scenario_ids").map(&:to_s).sort
  end
end
