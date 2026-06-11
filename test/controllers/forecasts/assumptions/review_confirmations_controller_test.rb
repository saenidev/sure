# frozen_string_literal: true

require "test_helper"

class Forecasts::Assumptions::ReviewConfirmationsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @user = users(:family_admin)
    @family = @user.family
    @plan = Forecasts::WorkspaceLoader.new(family: @family, today: Date.current).load.plan
    @assumption = @plan.forecast_assumptions.create!(
      family: @family, kind: "salary", name: "Derived Salary", status: :active,
      amount: 5200, currency: "USD",
      origin: :source_derived, confidence: :medium, review_state: :needs_review,
      params: { "frequency" => "monthly", "growth_policy" => "flat" }
    )
  end

  test "confirm flips needs_review to confirmed without bumping the lock and streams the card" do
    lock = @assumption.lock_version
    updated_at = @assumption.updated_at

    post forecasts_assumption_review_confirmation_path(@assumption), as: :turbo_stream

    assert_response :success
    @assumption.reload
    assert_equal "confirmed", @assumption.review_state
    assert_equal lock, @assumption.lock_version,
      "confirming must never bump the optimistic lock (it would 409 an open drawer)"
    assert_equal updated_at, @assumption.updated_at
    assert_select "turbo-stream[action=replace][target=?]",
      ActionView::RecordIdentifier.dom_id(@assumption), count: 1
  end

  test "confirming an already-confirmed assumption is a no-op 200 that still streams the card" do
    @assumption.update_columns(review_state: "confirmed")
    lock = @assumption.lock_version

    post forecasts_assumption_review_confirmation_path(@assumption), as: :turbo_stream

    assert_response :success
    @assumption.reload
    assert_equal "confirmed", @assumption.review_state
    assert_equal lock, @assumption.lock_version
    assert_select "turbo-stream[target=?]",
      ActionView::RecordIdentifier.dom_id(@assumption), count: 1
  end

  test "cross-family confirm is a 404 and writes nothing" do
    sign_in users(:empty)

    post forecasts_assumption_review_confirmation_path(@assumption), as: :turbo_stream

    assert_response :not_found
    assert_equal "needs_review", @assumption.reload.review_state
  end
end
