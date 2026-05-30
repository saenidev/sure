require "test_helper"

class Forecast::ScenariosControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @family = @user.family
    @family.forecast_scenarios.delete_all
    sign_in @user
  end

  # --- new / edit render inside the modal turbo frame ------------------------
  # Regression: the new/edit links open with frame: "modal", so the response
  # MUST contain a <turbo-frame id="modal"> or Turbo shows "content missing".

  test "new renders the form inside the modal turbo frame" do
    get new_forecast_scenario_url, headers: { "Turbo-Frame" => "modal" }

    assert_response :success
    # Exactly one modal frame: DS::Dialog already wraps in turbo-frame#modal, so
    # a manual turbo_frame_tag "modal" wrapper would nest a duplicate id and Turbo
    # would render "content missing".
    assert_select "turbo-frame#modal", count: 1
    assert_select "turbo-frame#modal form[data-turbo-frame=?]", "_top"
  end

  test "edit renders the form inside the modal turbo frame" do
    scenario = @family.forecast_scenarios.create!(name: "Editable", status: "active", created_by_user: @user)

    get edit_forecast_scenario_url(scenario), headers: { "Turbo-Frame" => "modal" }

    assert_response :success
    # Exactly one modal frame: DS::Dialog already wraps in turbo-frame#modal, so
    # a manual turbo_frame_tag "modal" wrapper would nest a duplicate id and Turbo
    # would render "content missing".
    assert_select "turbo-frame#modal", count: 1
    assert_select "turbo-frame#modal form[data-turbo-frame=?]", "_top"
  end

  # --- index -----------------------------------------------------------------

  test "index lists only the current family's scenarios grouped by status" do
    mine = @family.forecast_scenarios.create!(name: "My active", status: "active")
    disabled = @family.forecast_scenarios.create!(name: "My disabled", status: "disabled")
    other = families(:empty).forecast_scenarios.create!(name: "Foreign", status: "active")

    get forecast_scenarios_path

    assert_response :success
    assert_select "##{dom_id(mine)}"
    assert_select "##{dom_id(disabled)}"
    assert_select "##{dom_id(other)}", count: 0
  end

  test "index renders an empty state when the family has no scenarios" do
    get forecast_scenarios_path

    assert_response :success
    assert_select "[data-testid=scenarios-empty-state]"
  end

  # Regression: the "New scenario" trigger opens a modal, so it must be a GET
  # anchor that navigates the "modal" turbo frame -- NOT a button_to POST form
  # (which would POST to a GET-only route and make Turbo render "content
  # missing").
  test "index renders the new trigger as a GET modal link, not a POST form" do
    get forecast_scenarios_path

    assert_response :success

    new_path = new_forecast_scenario_path
    modal_link_hrefs = css_select("a[data-turbo-frame=modal]").map { |a| a["href"] }
    assert_includes modal_link_hrefs, new_path,
      "expected a GET <a> to #{new_path} in the modal frame (button_to POST regression -> Turbo 'content missing')"

    form_actions = css_select("form").map { |f| f["action"] }
    assert_not_includes form_actions, new_path,
      "the New scenario trigger must not be a button_to POST form to the GET-only #{new_path}"
  end

  test "index exposes scenario events in a visible row disclosure" do
    scenario = @family.forecast_scenarios.create!(name: "Move abroad", status: "active")
    event = scenario.forecast_events.create!(
      family: @family,
      name: "Visa fees",
      effect_type: "expense",
      behavior: "additive",
      amount: 1250,
      currency: @family.currency,
      starts_on: Date.current,
      status: "planned"
    )

    get forecast_scenarios_path

    assert_response :success
    assert_select "##{dom_id(scenario)} details[data-testid=scenario-events]"
    assert_select "##{dom_id(scenario)} summary", text: /Events \(1\)/
    assert_select "##{dom_id(scenario)} details[data-testid=scenario-events]", text: /#{Regexp.escape(event.name)}/
    assert_select "##{dom_id(scenario)} a[href=?]", forecast_events_path(scenario_id: scenario.id)
    assert_select "##{dom_id(scenario)} a[href=?][data-turbo-frame=modal]", new_forecast_event_path(scenario_id: scenario.id)
  end

  # --- create (happy path) ---------------------------------------------------

  test "create persists a scenario scoped to the current family" do
    assert_difference "@family.forecast_scenarios.count", 1 do
      post forecast_scenarios_path, params: {
        forecast_scenario: {
          name: "New job",
          description: "Higher salary",
          starts_on: Date.current,
          ends_on: Date.current + 1.year,
          display_order: 2,
          status: "active"
        }
      }
    end

    assert_redirected_to forecast_scenarios_path
    assert_equal "Scenario created.", flash[:notice]
    scenario = @family.forecast_scenarios.order(:created_at).last
    assert_equal "New job", scenario.name
    assert_equal 2, scenario.position
    assert_equal @user.id, scenario.created_by_user_id
    assert_equal "manual", scenario.approval_status
  end

  # --- create (validation -> 422) --------------------------------------------

  test "create with a blank name re-renders the form with a 422" do
    assert_no_difference "@family.forecast_scenarios.count" do
      post forecast_scenarios_path, params: {
        forecast_scenario: { name: "", status: "active" }
      }
    end

    assert_response :unprocessable_entity
    assert_select "form"
  end

  test "create with ends_on before starts_on is rejected with a 422" do
    assert_no_difference "@family.forecast_scenarios.count" do
      post forecast_scenarios_path, params: {
        forecast_scenario: {
          name: "Bad dates",
          starts_on: Date.current,
          ends_on: Date.current - 5.days,
          status: "active"
        }
      }
    end

    assert_response :unprocessable_entity
  end

  # --- create cannot set family_id / created_by_user_id via params -----------

  test "create ignores a family_id passed in params" do
    other_family = families(:empty)

    post forecast_scenarios_path, params: {
      forecast_scenario: {
        name: "Injection attempt",
        status: "active",
        family_id: other_family.id,
        created_by_user_id: users(:empty).id
      }
    }

    assert_redirected_to forecast_scenarios_path
    scenario = @family.forecast_scenarios.find_by(name: "Injection attempt")
    assert_not_nil scenario, "scenario must belong to the current family, not the injected one"
    assert_equal @family.id, scenario.family_id
    assert_equal @user.id, scenario.created_by_user_id
    assert_nil other_family.forecast_scenarios.find_by(name: "Injection attempt")
  end

  # --- update ----------------------------------------------------------------

  test "update changes attributes on the current family's scenario" do
    scenario = @family.forecast_scenarios.create!(name: "Old name", status: "active")

    patch forecast_scenario_path(scenario), params: {
      forecast_scenario: { name: "New name", display_order: 9 }
    }

    assert_redirected_to forecast_scenarios_path
    scenario.reload
    assert_equal "New name", scenario.name
    assert_equal 9, scenario.position
  end

  test "update with invalid data re-renders the form with a 422" do
    scenario = @family.forecast_scenarios.create!(name: "Valid", status: "active")

    patch forecast_scenario_path(scenario), params: {
      forecast_scenario: { name: "" }
    }

    assert_response :unprocessable_entity
    assert_equal "Valid", scenario.reload.name
  end

  # --- destroy ---------------------------------------------------------------

  test "destroy removes the current family's scenario" do
    scenario = @family.forecast_scenarios.create!(name: "Delete me", status: "active")

    assert_difference "@family.forecast_scenarios.count", -1 do
      delete forecast_scenario_path(scenario)
    end

    assert_redirected_to forecast_scenarios_path
  end

  # --- toggle (activate/deactivate is an UPDATE of status) -------------------

  test "toggle flips an active scenario to disabled via turbo stream" do
    scenario = @family.forecast_scenarios.create!(name: "Toggle me", status: "active")

    patch toggle_forecast_scenario_path(scenario), as: :turbo_stream

    assert_response :success
    assert_equal "disabled", scenario.reload.status
  end

  test "toggle flips a disabled scenario back to active" do
    scenario = @family.forecast_scenarios.create!(name: "Toggle me", status: "disabled")

    patch toggle_forecast_scenario_path(scenario), as: :turbo_stream

    assert_response :success
    assert_equal "active", scenario.reload.status
  end

  test "toggle on an archived scenario is rejected and never reactivates it" do
    scenario = @family.forecast_scenarios.create!(name: "Archived", status: "archived")

    patch toggle_forecast_scenario_path(scenario), as: :turbo_stream

    assert_response :unprocessable_entity
    assert_equal "archived", scenario.reload.status
  end

  # --- duplicate -------------------------------------------------------------

  test "duplicate deep-copies a scenario and its children into the family" do
    source = @family.forecast_scenarios.create!(name: "Source", status: "active")
    source.forecast_events.create!(
      family: @family,
      name: "Bonus",
      effect_type: "income",
      behavior: "additive",
      amount: 1000,
      currency: @family.currency,
      starts_on: Date.current,
      status: "planned"
    )

    assert_difference "@family.forecast_scenarios.count", 1 do
      post duplicate_forecast_scenario_path(source)
    end

    assert_redirected_to forecast_scenarios_path
    copy = @family.forecast_scenarios.where.not(id: source.id).order(:created_at).last
    assert_equal "disabled", copy.status
    assert_equal "manual", copy.approval_status
    assert_equal 1, copy.forecast_events.count
    assert_equal @family.id, copy.forecast_events.first.family_id
  end

  test "duplicate of a scenario with zero children succeeds" do
    source = @family.forecast_scenarios.create!(name: "Empty", status: "active")

    assert_difference "@family.forecast_scenarios.count", 1 do
      post duplicate_forecast_scenario_path(source)
    end

    assert_redirected_to forecast_scenarios_path
  end

  test "duplicate surfaces an error instead of 500 when a copy is invalid" do
    source = @family.forecast_scenarios.create!(name: "Source", status: "active")

    ForecastScenario.any_instance.stubs(:duplicate_for_family!)
      .raises(ActiveRecord::RecordInvalid.new(ForecastScenario.new))

    assert_no_difference "@family.forecast_scenarios.count" do
      post duplicate_forecast_scenario_path(source)
    end

    assert_redirected_to forecast_scenarios_path
    assert flash[:alert].present?
  end

  # --- authorization: cross-family ids are 404 -------------------------------

  test "edit on another family's scenario is denied with a 404" do
    foreign = families(:empty).forecast_scenarios.create!(name: "Foreign", status: "active")

    get edit_forecast_scenario_path(foreign)

    assert_response :not_found
  end

  test "update on another family's scenario is denied with a 404" do
    foreign = families(:empty).forecast_scenarios.create!(name: "Foreign", status: "active")

    patch forecast_scenario_path(foreign), params: {
      forecast_scenario: { name: "Hijacked" }
    }

    assert_response :not_found
    assert_equal "Foreign", foreign.reload.name
  end

  test "destroy on another family's scenario is denied with a 404" do
    foreign = families(:empty).forecast_scenarios.create!(name: "Foreign", status: "active")

    assert_no_difference "ForecastScenario.count" do
      delete forecast_scenario_path(foreign)
    end

    assert_response :not_found
  end

  test "toggle on another family's scenario is denied with a 404" do
    foreign = families(:empty).forecast_scenarios.create!(name: "Foreign", status: "active")

    patch toggle_forecast_scenario_path(foreign), as: :turbo_stream

    assert_response :not_found
    assert_equal "active", foreign.reload.status
  end

  test "a user cannot duplicate another family's scenario into their own family" do
    foreign = families(:empty).forecast_scenarios.create!(name: "Foreign", status: "active")

    assert_no_difference "@family.forecast_scenarios.count" do
      post duplicate_forecast_scenario_path(foreign)
    end

    assert_response :not_found
  end
end
