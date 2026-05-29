require "test_helper"

class Forecast::ReviewsControllerTest < ActionDispatch::IntegrationTest
  include ForecastRunGroupTestHelper

  setup do
    @user = users(:family_admin)
    @family = @user.family
    @family.forecast_run_groups.delete_all
    @family.forecast_scenarios.delete_all
    sign_in @user
  end

  # build_completed_run_group does not create a review (only Forecast::Runner
  # does). Tests that need an existing review create the draft shell up front,
  # mirroring what the Runner persists.
  def ensure_review(group, family: @family, user: @user)
    group.forecast_review || group.create_forecast_review!(
      family: family, user: user, source: "manual", status: "draft"
    )
  end

  # --- show ------------------------------------------------------------------

  test "show renders the review surface for the current family's group" do
    group = build_completed_run_group(family: @family, user: @user)

    get forecast_review_path(group)

    assert_response :success
    assert_select "h1", text: group.name
  end

  test "show builds a draft review when the group has none" do
    group = build_completed_run_group(family: @family, user: @user)
    group.forecast_review&.destroy

    assert_difference -> { ForecastReview.count }, 1 do
      get forecast_review_path(group)
    end

    assert_response :success
    assert_equal "draft", group.reload.forecast_review.status
  end

  test "show surfaces a failed group's error rather than a blank facts panel" do
    group = build_failed_run_group(family: @family, user: @user, error_message: "MoneyConverter::MissingRate: no rate")

    get forecast_review_path(group)

    assert_response :success
    assert_match "MoneyConverter::MissingRate", response.body
  end

  test "show renders stored Hermes drafts, recommendations, and questions" do
    group = build_completed_run_group(family: @family, user: @user)
    ensure_review(group).update!(response_packet: {
      "draft_scenarios" => [ { "name" => "Refinance", "description" => "Lower rate", "events" => [ {} ] } ],
      "recommendations" => [ { "title" => "Build a buffer", "body" => "Hold 3 months expenses" }, "Pay down the card" ],
      "follow_up_questions" => [ "Are you planning a move?" ]
    })

    get forecast_review_path(group)

    assert_response :success
    assert_match "Refinance", response.body
    assert_match "Build a buffer", response.body
    assert_match "Pay down the card", response.body
    assert_match "Are you planning a move?", response.body
  end

  # --- update: status transitions --------------------------------------------

  test "update transitions draft -> awaiting_approval -> approved and persists" do
    group = build_completed_run_group(family: @family, user: @user)
    review = ensure_review(group)

    patch forecast_review_path(group), params: { forecast_review: { status: "awaiting_approval" } }
    assert_redirected_to forecast_review_path(group)
    assert_equal "awaiting_approval", review.reload.status

    patch forecast_review_path(group), params: { forecast_review: { status: "approved" } }
    assert_redirected_to forecast_review_path(group)
    review.reload
    assert_equal "approved", review.status
    assert_not_nil review.approved_at
  end

  test "rejecting stamps rejected_at" do
    group = build_completed_run_group(family: @family, user: @user)
    review = ensure_review(group)

    patch forecast_review_path(group), params: { forecast_review: { status: "rejected" } }

    assert_equal "rejected", review.reload.status
    assert_not_nil review.rejected_at
  end

  test "an invalid status value is rejected with a 422 and does not change the review" do
    group = build_completed_run_group(family: @family, user: @user)
    review = ensure_review(group)

    patch forecast_review_path(group), params: { forecast_review: { status: "totally_bogus" } }

    assert_response :unprocessable_entity
    assert_equal "draft", review.reload.status
  end

  test "status param cannot be set to an arbitrary non-whitelisted value" do
    group = build_completed_run_group(family: @family, user: @user)

    patch forecast_review_path(group), params: { forecast_review: { status: "applied; DROP TABLE" } }

    assert_response :unprocessable_entity
    assert_equal "draft", group.reload.forecast_review.status
  end

  # --- immutability: mutating the review never mutates the run group ----------

  test "transitioning the review status leaves the immutable run group output unchanged" do
    group = build_run_group_with_series(family: @family, user: @user, days: 3, months: 2)
    run = group.forecast_runs.first
    day_count = run.forecast_days.count
    month_count = run.forecast_months.count
    group_updated_at = group.updated_at

    patch forecast_review_path(group), params: { forecast_review: { status: "awaiting_approval" } }

    assert_redirected_to forecast_review_path(group)
    group.reload
    assert_equal "completed", group.status
    assert_equal group_updated_at.to_i, group.updated_at.to_i, "run group must not be touched by a review transition"
    assert_equal day_count, run.reload.forecast_days.count
    assert_equal month_count, run.forecast_months.count
  end

  # --- submit_to_hermes: stubbed external boundary handled gracefully ---------

  test "submit_to_hermes builds and saves the packet and surfaces a graceful notice when Hermes is not configured" do
    group = build_completed_run_group(family: @family, user: @user)
    review = ensure_review(group)

    # No endpoint configured (the default) -> HermesClient raises NotConfigured,
    # which the controller catches and renders as a notice, NOT a 500.
    assert_not Forecast::HermesClient.configured?

    post submit_to_hermes_forecast_review_path(group)

    assert_redirected_to forecast_review_path(group)
    assert_equal I18n.t("forecast.reviews.submit_to_hermes.not_configured"), flash[:notice]
    # The deterministic packet was still built and persisted onto the request.
    assert_equal Forecast::PacketBuilder::SCHEMA_VERSION, review.reload.request_packet["schema_version"]
  end

  test "submit_to_hermes surfaces an alert (not a 500) when the group has not completed" do
    group = build_failed_run_group(family: @family, user: @user)
    group.create_forecast_review!(family: @family, user: @user, source: "manual", status: "draft")

    post submit_to_hermes_forecast_review_path(group)

    assert_redirected_to forecast_review_path(group)
    assert_equal I18n.t("forecast.reviews.submit_to_hermes.incomplete"), flash[:alert]
  end

  # --- approve_draft: Hermes draft -> real, disabled, approved scenario -------

  test "approve_draft converts a stored Hermes draft into a disabled approved family scenario with child events" do
    group = build_completed_run_group(family: @family, user: @user)
    review = ensure_review(group)
    review.update!(response_packet: {
      "draft_scenarios" => [
        {
          "name" => "Refinance mortgage",
          "description" => "Lower the rate",
          "events" => [
            { "name" => "Lower payment", "effect_type" => "expense", "amount" => "1500", "starts_on" => Date.current.iso8601 }
          ]
        }
      ]
    })

    assert_difference -> { @family.forecast_scenarios.count }, 1 do
      post approve_draft_forecast_review_path(group), params: { draft_index: 0 }
    end

    assert_redirected_to forecast_review_path(group)
    scenario = @family.forecast_scenarios.order(:created_at).last
    assert_equal "Refinance mortgage", scenario.name
    # Hermes boundary: approved but NOT auto-active.
    assert_equal "disabled", scenario.status
    assert_equal "approved", scenario.approval_status
    assert_equal @family.id, scenario.family_id
    assert_equal @user.id, scenario.created_by_user_id
    # Child draft events are copied (disabled).
    assert_equal 1, scenario.forecast_events.count
    event = scenario.forecast_events.first
    assert_equal "Lower payment", event.name
    assert_equal "disabled", event.status
    assert_equal @family.id, event.family_id
  end

  test "approve_draft with a missing draft index does not create a scenario" do
    group = build_completed_run_group(family: @family, user: @user)
    ensure_review(group).update!(response_packet: { "draft_scenarios" => [] })

    assert_no_difference -> { @family.forecast_scenarios.count } do
      post approve_draft_forecast_review_path(group), params: { draft_index: 5 }
    end

    assert_redirected_to forecast_review_path(group)
    assert_equal I18n.t("forecast.reviews.approve_draft.draft_not_found"), flash[:alert]
  end

  test "rejecting a review does not create any scenario from its drafts" do
    group = build_completed_run_group(family: @family, user: @user)
    review = ensure_review(group)
    review.update!(response_packet: {
      "draft_scenarios" => [ { "name" => "Draft", "events" => [] } ]
    })

    assert_no_difference -> { @family.forecast_scenarios.count } do
      patch forecast_review_path(group), params: { forecast_review: { status: "rejected" } }
    end

    assert_equal "rejected", review.reload.status
  end

  test "approve_draft never creates a scenario in another family" do
    # The draft payload cannot smuggle a foreign family — family is set
    # server-side from Current.family.
    group = build_completed_run_group(family: @family, user: @user)
    ensure_review(group).update!(response_packet: {
      "draft_scenarios" => [ { "name" => "Injected", "family_id" => families(:empty).id, "events" => [] } ]
    })

    post approve_draft_forecast_review_path(group), params: { draft_index: 0 }

    scenario = @family.forecast_scenarios.order(:created_at).last
    assert_equal @family.id, scenario.family_id
    assert_equal 0, families(:empty).forecast_scenarios.where(name: "Injected").count
  end

  # --- authorization: cross-family ids are 404 -------------------------------

  test "show for another family's run group is denied with a 404" do
    other_group = build_completed_run_group(family: families(:empty), user: users(:empty))

    get forecast_review_path(other_group)

    assert_response :not_found
  end

  test "update for another family's run group is denied with a 404" do
    other_group = build_completed_run_group(family: families(:empty), user: users(:empty))

    patch forecast_review_path(other_group), params: { forecast_review: { status: "approved" } }

    assert_response :not_found
  end

  test "approve_draft for another family's run group is denied with a 404" do
    other_group = build_completed_run_group(family: families(:empty), user: users(:empty))

    post approve_draft_forecast_review_path(other_group), params: { draft_index: 0 }

    assert_response :not_found
  end

  test "submit_to_hermes for another family's run group is denied with a 404" do
    other_group = build_completed_run_group(family: families(:empty), user: users(:empty))

    post submit_to_hermes_forecast_review_path(other_group)

    assert_response :not_found
  end
end
