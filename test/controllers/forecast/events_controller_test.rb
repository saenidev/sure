require "test_helper"

class Forecast::EventsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @family = @user.family
    @account = accounts(:depository)
    @destination_account = accounts(:credit_card)
    @category = categories(:food_and_drink)
    @family.forecast_events.delete_all
    @family.forecast_scenarios.delete_all
    @scenario = @family.forecast_scenarios.create!(name: "Base", status: "active")
    sign_in @user
  end

  def base_params(overrides = {})
    {
      name: "Test event",
      effect_type: "income",
      amount: "1000",
      currency: "USD",
      starts_on: Date.current.to_s,
      status: "planned",
      probability_weight: "1.0"
    }.merge(overrides)
  end

  # --- index -----------------------------------------------------------------

  test "new renders the form inside the modal turbo frame" do
    get new_forecast_event_url, headers: { "Turbo-Frame" => "modal" }

    assert_response :success
    assert_select "turbo-frame#modal", count: 1
    assert_select "turbo-frame#modal form[data-turbo-frame=?]", "_top"
  end

  test "new within a future scenario defaults the event date to the scenario start" do
    @scenario.update!(starts_on: 2.months.from_now.to_date)

    get new_forecast_event_url(scenario_id: @scenario.id), headers: { "Turbo-Frame" => "modal" }

    assert_response :success
    assert_select "input[name='forecast_event[starts_on]'][value=?]", @scenario.starts_on.to_s
  end

  test "edit renders the form inside the modal turbo frame" do
    event = @family.forecast_events.create!(base_params_model)

    get edit_forecast_event_url(event), headers: { "Turbo-Frame" => "modal" }

    assert_response :success
    assert_select "turbo-frame#modal", count: 1
    assert_select "turbo-frame#modal form[data-turbo-frame=?]", "_top"
  end

  test "index lists only the current family's events" do
    mine = @family.forecast_events.create!(base_params_model)
    other = families(:empty).forecast_events.create!(
      name: "Foreign", effect_type: "income", behavior: "additive",
      amount: 5, currency: "USD", starts_on: Date.current, status: "planned"
    )

    get forecast_events_path

    assert_response :success
    assert_select "##{dom_id(mine)}"
    assert_select "##{dom_id(other)}", count: 0
    assert_select "[data-testid=forecast-events-summary]"
  end

  test "index breadcrumbs are nested under forecast" do
    get forecast_events_path

    assert_response :success
    assert_equal [
      [ "Home", root_path ],
      [ "Forecast", forecast_path ],
      [ "Events", nil ]
    ], @controller.send(:breadcrumbs)
  end

  test "index forecast breadcrumb uses a safe return target when provided" do
    return_to = forecast_path(tab: "reconciliation")

    get forecast_events_path(return_to: return_to)

    assert_response :success
    assert_equal [
      [ "Home", root_path ],
      [ "Forecast", return_to ],
      [ "Events", nil ]
    ], @controller.send(:breadcrumbs)
  end

  test "index renders an empty state when the family has no events" do
    get forecast_events_path

    assert_response :success
    assert_select "[data-testid=events-empty-state]"
  end

  test "index renders the new trigger as a GET modal link, not a POST form" do
    get forecast_events_path

    assert_response :success

    new_path = new_forecast_event_path
    modal_link_hrefs = css_select("a[data-turbo-frame=modal]").map { |a| a["href"] }
    assert_includes modal_link_hrefs, new_path,
      "expected a GET <a> to #{new_path} in the modal frame (button_to POST regression -> Turbo 'content missing')"

    form_actions = css_select("form").map { |f| f["action"] }
    assert_not_includes form_actions, new_path,
      "the New event trigger must not be a button_to POST form to the GET-only #{new_path}"
  end

  test "index scoped to a scenario lists only that scenario's events" do
    in_scenario = @family.forecast_events.create!(base_params_model(forecast_scenario: @scenario))
    family_level = @family.forecast_events.create!(base_params_model(name: "Family level"))

    get forecast_events_path(scenario_id: @scenario.id)

    assert_response :success
    assert_select "##{dom_id(in_scenario)}"
    assert_select "##{dom_id(family_level)}", count: 0
  end

  test "scenario-scoped index breadcrumbs stay under forecast" do
    return_to = forecast_path(tab: "scenarios")

    get forecast_events_path(scenario_id: @scenario.id, return_to: return_to)

    assert_response :success
    assert_equal [
      [ "Home", root_path ],
      [ "Forecast", return_to ],
      [ "Events", nil ]
    ], @controller.send(:breadcrumbs)
  end

  # --- create happy paths: each amount effect type ---------------------------

  ForecastEvent::AMOUNT_EFFECT_TYPES.each do |effect_type|
    test "create persists a #{effect_type} amount event" do
      params =
        if effect_type == "transfer"
          base_params(
            effect_type: "transfer",
            account_id: @account.id,
            destination_account_id: @destination_account.id
          )
        else
          base_params(effect_type: effect_type)
        end

      assert_difference "@family.forecast_events.count", 1 do
        post forecast_events_path, params: { forecast_event: params }
      end

      assert_redirected_to forecast_events_path
      assert_equal "Event created.", flash[:notice]
      event = @family.forecast_events.order(:created_at).last
      assert_equal effect_type, event.effect_type
      assert_equal "additive", event.behavior
      assert_equal @family.id, event.family_id
    end
  end

  test "create a same-currency transfer with two family accounts" do
    assert_difference "@family.forecast_events.count", 1 do
      post forecast_events_path, params: { forecast_event: base_params(
        effect_type: "transfer",
        account_id: @account.id,
        destination_account_id: @destination_account.id
      ) }
    end

    assert_redirected_to forecast_events_path
    event = @family.forecast_events.order(:created_at).last
    assert_equal @account.id, event.account_id
    assert_equal @destination_account.id, event.destination_account_id
  end

  test "create a recurring monthly event with a valid recurrence rule" do
    assert_difference "@family.forecast_events.count", 1 do
      post forecast_events_path, params: { forecast_event: base_params(
        effect_type: "expense",
        category_id: @category.id,
        recurring: "1",
        ends_on: (Date.current + 1.year).to_s,
        recurrence_rule: { frequency: "monthly", interval: "2", day_of_month: "15" }
      ) }
    end

    event = @family.forecast_events.order(:created_at).last
    assert event.recurring?
    assert_equal "monthly", event.recurrence_rule["frequency"]
    assert_equal 2, event.recurrence_rule["interval"]
    assert_equal 15, event.recurrence_rule["day_of_month"]
  end

  test "create within a scenario links the event and redirects back to scenario events" do
    assert_difference "@scenario.forecast_events.count", 1 do
      post forecast_events_path(scenario_id: @scenario.id),
           params: { forecast_event: base_params(forecast_scenario_id: @scenario.id) }
    end

    assert_redirected_to forecast_events_path(scenario_id: @scenario.id)
    event = @family.forecast_events.order(:created_at).last
    assert_equal @scenario.id, event.forecast_scenario_id
    assert_not event.include_baseline?
    assert_equal [ @scenario.id ], event.scenario_membership_ids
  end

  test "create can share one event across multiple scenarios" do
    other_scenario = @family.forecast_scenarios.create!(name: "Other option", status: "active")

    assert_difference "@family.forecast_events.count", 1 do
      post forecast_events_path,
           params: {
             forecast_event: base_params(
               include_baseline: "0",
               forecast_scenario_ids: [ @scenario.id, other_scenario.id ]
             )
           }
    end

    assert_redirected_to forecast_events_path
    event = @family.forecast_events.order(:created_at).last
    assert_not event.include_baseline?
    assert_equal [ @scenario.id, other_scenario.id ].sort, event.scenario_membership_ids.sort
  end

  test "create within a scenario preserves return target on redirect" do
    return_to = forecast_path(tab: "scenarios")

    assert_difference "@scenario.forecast_events.count", 1 do
      post forecast_events_path(scenario_id: @scenario.id, return_to: return_to),
           params: { forecast_event: base_params(forecast_scenario_id: @scenario.id) }
    end

    assert_redirected_to forecast_events_path(scenario_id: @scenario.id, return_to: return_to)
  end

  # --- create validation / failure surfacing (422) ---------------------------

  test "amount effect without an amount is rejected with a 422" do
    assert_no_difference "@family.forecast_events.count" do
      post forecast_events_path, params: { forecast_event: base_params(effect_type: "income", amount: "") }
    end

    assert_response :unprocessable_entity
    assert_select "form"
  end

  test "income with a negative amount is rejected with a 422" do
    assert_no_difference "@family.forecast_events.count" do
      post forecast_events_path, params: { forecast_event: base_params(effect_type: "income", amount: "-50") }
    end

    assert_response :unprocessable_entity
  end

  test "transfer missing destination account is rejected with a 422" do
    assert_no_difference "@family.forecast_events.count" do
      post forecast_events_path, params: { forecast_event: base_params(
        effect_type: "transfer",
        account_id: @account.id
      ) }
    end

    assert_response :unprocessable_entity
  end

  test "cross-currency transfer without destination metadata is rejected with a 422" do
    @destination_account.update!(currency: "EUR")

    assert_no_difference "@family.forecast_events.count" do
      post forecast_events_path, params: { forecast_event: base_params(
        effect_type: "transfer",
        account_id: @account.id,
        destination_account_id: @destination_account.id
      ) }
    end

    assert_response :unprocessable_entity
  end

  test "cross-currency transfer with destination metadata is accepted" do
    @destination_account.update!(currency: "EUR")

    assert_difference "@family.forecast_events.count", 1 do
      post forecast_events_path, params: { forecast_event: base_params(
        effect_type: "transfer",
        account_id: @account.id,
        destination_account_id: @destination_account.id,
        source_metadata: { destination_amount: "900", destination_currency: "EUR" }
      ) }
    end

    event = @family.forecast_events.order(:created_at).last
    assert_equal "900", event.source_metadata["destination_amount"]
    assert_equal "EUR", event.source_metadata["destination_currency"]
  end

  test "recurrence rule with interval 0 is rejected with a 422" do
    assert_no_difference "@family.forecast_events.count" do
      post forecast_events_path, params: { forecast_event: base_params(
        recurring: "1",
        recurrence_rule: { frequency: "monthly", interval: "0", day_of_month: "1" }
      ) }
    end

    assert_response :unprocessable_entity
  end

  test "recurrence rule with interval 99 is rejected with a 422" do
    assert_no_difference "@family.forecast_events.count" do
      post forecast_events_path, params: { forecast_event: base_params(
        recurring: "1",
        recurrence_rule: { frequency: "monthly", interval: "99", day_of_month: "1" }
      ) }
    end

    assert_response :unprocessable_entity
  end

  test "recurrence frequency daily is rejected with a 422" do
    assert_no_difference "@family.forecast_events.count" do
      post forecast_events_path, params: { forecast_event: base_params(
        recurring: "1",
        recurrence_rule: { frequency: "daily", interval: "1" }
      ) }
    end

    assert_response :unprocessable_entity
  end

  test "ends_on before starts_on is rejected with a 422" do
    assert_no_difference "@family.forecast_events.count" do
      post forecast_events_path, params: { forecast_event: base_params(
        starts_on: Date.current.to_s,
        ends_on: (Date.current - 5.days).to_s
      ) }
    end

    assert_response :unprocessable_entity
  end

  test "market shock accepts a negative amount where directional effects require positivity" do
    assert_difference "@family.forecast_events.count", 1 do
      post forecast_events_path, params: { forecast_event: base_params(
        effect_type: "market_shock",
        amount: "-1000"
      ) }
    end

    assert_redirected_to forecast_events_path
    event = @family.forecast_events.order(:created_at).last
    assert_equal "market_shock", event.effect_type
    assert_equal(-1000, event.amount.to_i)
  end

  # --- authorization / scoping -----------------------------------------------

  test "create cannot set family_id via params" do
    other_family = families(:empty)

    post forecast_events_path, params: { forecast_event: base_params(family_id: other_family.id) }

    assert_redirected_to forecast_events_path
    event = @family.forecast_events.order(:created_at).last
    assert_equal @family.id, event.family_id
    assert_nil other_family.forecast_events.find_by(name: "Test event")
  end

  test "a foreign account id is rejected by the model and not persisted" do
    foreign_account = accounts(:other_asset)
    foreign_account.update!(family: families(:empty), owner: users(:empty))

    assert_no_difference "@family.forecast_events.count" do
      post forecast_events_path, params: { forecast_event: base_params(
        effect_type: "transfer",
        account_id: foreign_account.id,
        destination_account_id: @destination_account.id
      ) }
    end

    assert_response :unprocessable_entity
  end

  test "a foreign scenario id is denied with a 404 on create" do
    foreign_scenario = families(:empty).forecast_scenarios.create!(name: "Foreign", status: "active")

    assert_no_difference "ForecastEvent.count" do
      post forecast_events_path(scenario_id: foreign_scenario.id),
           params: { forecast_event: base_params }
    end

    assert_response :not_found
  end

  test "edit on another family's event is denied with a 404" do
    foreign = families(:empty).forecast_events.create!(
      name: "Foreign", effect_type: "income", behavior: "additive",
      amount: 5, currency: "USD", starts_on: Date.current, status: "planned"
    )

    get edit_forecast_event_path(foreign)

    assert_response :not_found
  end

  test "update on another family's event is denied with a 404" do
    foreign = families(:empty).forecast_events.create!(
      name: "Foreign", effect_type: "income", behavior: "additive",
      amount: 5, currency: "USD", starts_on: Date.current, status: "planned"
    )

    patch forecast_event_path(foreign), params: { forecast_event: { name: "Hijacked" } }

    assert_response :not_found
    assert_equal "Foreign", foreign.reload.name
  end

  test "destroy on another family's event is denied with a 404" do
    foreign = families(:empty).forecast_events.create!(
      name: "Foreign", effect_type: "income", behavior: "additive",
      amount: 5, currency: "USD", starts_on: Date.current, status: "planned"
    )

    assert_no_difference "ForecastEvent.count" do
      delete forecast_event_path(foreign)
    end

    assert_response :not_found
  end

  # --- update / destroy happy paths ------------------------------------------

  test "update changes attributes on the current family's event" do
    event = @family.forecast_events.create!(base_params_model)

    patch forecast_event_path(event), params: { forecast_event: { name: "Renamed", amount: "2500" } }

    assert_redirected_to forecast_events_path
    event.reload
    assert_equal "Renamed", event.name
    assert_equal 2500, event.amount.to_i
    assert_equal "additive", event.behavior
  end

  test "update changes baseline and scenario membership scope" do
    other_scenario = @family.forecast_scenarios.create!(name: "Other option", status: "active")
    event = @family.forecast_events.create!(base_params_model)

    patch forecast_event_path(event), params: {
      forecast_event: {
        include_baseline: "0",
        forecast_scenario_ids: [ @scenario.id, other_scenario.id ]
      }
    }

    assert_redirected_to forecast_events_path
    event.reload
    assert_not event.include_baseline?
    assert_equal [ @scenario.id, other_scenario.id ].sort, event.scenario_membership_ids.sort
  end

  test "update with invalid data re-renders the form with a 422" do
    event = @family.forecast_events.create!(base_params_model)

    patch forecast_event_path(event), params: { forecast_event: { name: "", amount: "10" } }

    assert_response :unprocessable_entity
    assert_equal "Test event", event.reload.name
  end

  test "destroy removes the current family's event" do
    event = @family.forecast_events.create!(base_params_model)

    assert_difference "@family.forecast_events.count", -1 do
      delete forecast_event_path(event)
    end

    assert_redirected_to forecast_events_path
  end

  private
    # Model-shaped attributes (behavior set, types coerced) for creating
    # fixtures directly through the association in tests.
    def base_params_model(overrides = {})
      {
        name: "Test event",
        effect_type: "income",
        behavior: "additive",
        amount: 1000,
        currency: "USD",
        starts_on: Date.current,
        status: "planned",
        probability_weight: 1.0
      }.merge(overrides)
    end
end
