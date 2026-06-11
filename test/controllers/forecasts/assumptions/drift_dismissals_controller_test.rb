# frozen_string_literal: true

require "test_helper"

class Forecasts::Assumptions::DriftDismissalsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @user = users(:family_admin)
    @family = @user.family
    @plan = Forecasts::WorkspaceLoader.new(family: @family, today: Date.current).load.plan
    @assumption = @plan.forecast_assumptions.create!(
      family: @family, kind: "salary", name: "Salary", status: :active,
      amount: 1100, currency: "USD",
      params: { "frequency" => "monthly", "growth_policy" => "flat" }
    )
    # The Task-5 scanner writes drift via update_columns; tests seed the same way
    # so lock_version stays untouched by the seeding itself.
    @assumption.update_columns(drift: drifted_payload)
  end

  test "soft dismiss remembers the proposed amount, clears drift, streams the card, keeps the lock" do
    lock = @assumption.lock_version

    post forecasts_assumption_drift_dismissal_path(@assumption), as: :turbo_stream

    assert_response :success
    @assumption.reload
    assert_nil @assumption.drift
    assert_equal BigDecimal("1340.0"), @assumption.drift_dismissed_amount
    assert_nil @assumption.drift_silenced_at
    assert_equal lock, @assumption.lock_version,
      "dismissal must never bump the optimistic lock (it would 409 an open drawer)"
    assert_select "turbo-stream[action=replace][target=?]",
      ActionView::RecordIdentifier.dom_id(@assumption), count: 1
  end

  test "permanent dismiss silences future nudges instead of pinning an amount" do
    post forecasts_assumption_drift_dismissal_path(@assumption),
      params: { permanent: "1" }, as: :turbo_stream

    assert_response :success
    @assumption.reload
    assert_nil @assumption.drift
    assert_not_nil @assumption.drift_silenced_at
    assert_nil @assumption.drift_dismissed_amount
  end

  test "source-gone acknowledge makes the card genuinely manual and the notice renders only once" do
    @assumption.update_columns(
      origin: "source_derived",
      source_record_type: "RecurringTransaction",
      source_record_id: SecureRandom.uuid,
      drift: { "status" => "source_gone", "computed_at" => Time.current.iso8601 }
    )
    lock = @assumption.lock_version

    post forecasts_assumption_drift_dismissal_path(@assumption), as: :turbo_stream

    assert_response :success
    @assumption.reload
    assert_nil @assumption.drift
    assert_nil @assumption.source_record_type
    assert_nil @assumption.source_record_id
    assert_equal "user_created", @assumption.origin,
      "acknowledge flips origin so the card is genuinely manual"
    assert_equal lock, @assumption.lock_version
    # The streamed card is the post-acknowledge state: no notice strip, no
    # "From your data" provenance label, no refresh-from-data trigger.
    assert_select "[role=status]", count: 0
    assert_not_includes response.body, I18n.t("forecasts.workspace.card.derived")
    assert_select "a[href=?]", forecasts_assumption_resync_path(@assumption), count: 0
  end

  test "dismissal without any drift is an idempotent no-op that still streams the card" do
    @assumption.update_columns(drift: nil)
    lock = @assumption.lock_version

    post forecasts_assumption_drift_dismissal_path(@assumption), as: :turbo_stream

    assert_response :success
    @assumption.reload
    assert_nil @assumption.drift_dismissed_amount
    assert_nil @assumption.drift_silenced_at
    assert_equal lock, @assumption.lock_version
    assert_select "turbo-stream[target=?]",
      ActionView::RecordIdentifier.dom_id(@assumption), count: 1
  end

  test "cross-family dismissal is a 404 and writes nothing" do
    sign_in users(:empty)

    post forecasts_assumption_drift_dismissal_path(@assumption), as: :turbo_stream

    assert_response :not_found
    assert_equal "drifted", @assumption.reload.drift["status"]
  end

  test "model drift helpers parse the scanner payload" do
    assert @assumption.drift_nudge?
    assert_not @assumption.drift_source_gone?
    assert_equal BigDecimal("1340.0"), @assumption.drift_proposed_amount

    @assumption.update_columns(drift: { "status" => "source_gone" })
    @assumption.reload
    assert_not @assumption.drift_nudge?
    assert @assumption.drift_source_gone?
    assert_nil @assumption.drift_proposed_amount

    @assumption.update_columns(drift: nil)
    @assumption.reload
    assert_not @assumption.drift_nudge?
    assert_not @assumption.drift_source_gone?
  end

  private
    # Mirrors the Task-4 scanner contract: decimal STRINGS, iso8601 time,
    # basis "source_rederive" (Forecasts::Drift::Scanner::BASIS).
    def drifted_payload
      {
        "status" => "drifted",
        "proposed_amount" => "1340.0",
        "current_amount" => "1100.0",
        "relative" => "0.218",
        "basis" => "source_rederive",
        "computed_at" => Time.current.iso8601
      }
    end
end
