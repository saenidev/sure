# frozen_string_literal: true

require "test_helper"

# Per-card "refresh from data" re-sync for source-derived assumptions.
# show (GET) is a pure preview that re-runs Forecasts::Derivation and streams
# the card in a proposal / in-sync / source-gone state; it never writes.
class Forecasts::Assumptions::ResyncsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @user = users(:family_admin)
    @family = @user.family
    @payroll = @family.recurring_transactions.create!(
      account: accounts(:depository),
      name: "Acme Payroll",
      amount: -5_000,
      currency: "USD",
      expected_day_of_month: 1,
      last_occurrence_date: Date.current - 1.month,
      next_expected_date: Date.current + 1.month,
      status: "active",
      occurrence_count: 6
    )
    @plan = Forecasts::WorkspaceLoader.new(family: @family, today: Date.current).load.plan
    @assumption = @plan.forecast_assumptions
      .where(kind: "salary", origin: "source_derived").sole
  end

  test "show streams a proposal card when the source amount changed" do
    @payroll.update!(amount: -6_000)

    get forecasts_assumption_resync_path(@assumption), as: :turbo_stream

    assert_response :success
    streams = css_select("turbo-stream").map { |s| s["target"] }
    assert_includes streams, ActionView::RecordIdentifier.dom_id(@assumption)
    # Server-side formatted current -> proposed amounts.
    assert_includes response.body, Money.new(BigDecimal("5000"), "USD").format
    assert_includes response.body, Money.new(BigDecimal("6000"), "USD").format
    # Accept posts back with the lock token as the ONLY derived-value-free payload.
    assert_select "form[action=?][method=post]", forecasts_assumption_resync_path(@assumption)
    assert_select "input[name=?][value=?]", "expected_lock_version", @assumption.lock_version.to_s
    # Keep-current is a plain GET back to the card.
    assert_select "a[href=?]", forecasts_assumption_resync_path(@assumption, cancel: 1)
  end

  test "show streams an already-in-sync state when nothing changed" do
    get forecasts_assumption_resync_path(@assumption), as: :turbo_stream

    assert_response :success
    assert_includes response.body, I18n.t("forecasts.workspace.card.resync.in_sync")
    assert_select "form[action=?]", forecasts_assumption_resync_path(@assumption), count: 0
  end

  test "show treats a within-a-cent difference as in sync" do
    proposal = Forecasts::Derivation::Proposal.new(
      kind: "salary", name: "Acme Payroll", amount: BigDecimal("5000.004"),
      currency: "USD", params: {}, confidence: "medium",
      source_record: @payroll, source_refs: {}, needs_review: true
    )
    Forecasts::Derivation.any_instance.stubs(:salary_proposal).returns(proposal)

    get forecasts_assumption_resync_path(@assumption), as: :turbo_stream

    assert_response :success
    assert_includes response.body, I18n.t("forecasts.workspace.card.resync.in_sync")
  end

  test "show streams a source-gone message when the source record is missing" do
    @payroll.destroy!

    get forecasts_assumption_resync_path(@assumption), as: :turbo_stream

    assert_response :success
    assert_includes response.body, I18n.t("forecasts.workspace.card.resync.source_gone")
    # No accept affordance when there is nothing to apply.
    assert_select "form[action=?]", forecasts_assumption_resync_path(@assumption), count: 0
  end

  test "show with cancel streams the plain card (keep current)" do
    get forecasts_assumption_resync_path(@assumption, cancel: 1), as: :turbo_stream

    assert_response :success
    streams = css_select("turbo-stream").map { |s| s["target"] }
    assert_includes streams, ActionView::RecordIdentifier.dom_id(@assumption)
    assert_not_includes response.body, I18n.t("forecasts.workspace.card.resync.in_sync")
    assert_not_includes response.body, I18n.t("forecasts.workspace.card.resync.source_gone")
    # The plain derived card still carries the refresh trigger.
    assert_select "a[href=?]", forecasts_assumption_resync_path(@assumption)
  end

  test "show is family-scoped" do
    sign_in users(:empty)
    get forecasts_assumption_resync_path(@assumption), as: :turbo_stream
    assert_response :not_found
  end

  test "show rejects a non-derived assumption" do
    manual = @plan.forecast_assumptions.create!(
      family: @family, kind: "salary", name: "Manual salary", status: :active,
      amount: 4_000, currency: "USD",
      params: { "frequency" => "monthly", "growth_policy" => "flat" }
    )

    get forecasts_assumption_resync_path(manual), as: :turbo_stream

    assert_response :unprocessable_entity
  end

  # --- create (accept) -------------------------------------------------------

  test "accept re-derives server-side, applies the values, and streams the full patch set" do
    @assumption.update!(name: "My salary") # user rename must survive the accept
    @payroll.update!(amount: -6_000)
    version_before = @plan.reload.current_plan_version

    post forecasts_assumption_resync_path(@assumption),
      params: { expected_lock_version: @assumption.reload.lock_version.to_s },
      as: :turbo_stream

    assert_response :success
    @assumption.reload
    assert_equal 6000, @assumption.amount
    assert_equal "My salary", @assumption.name
    assert_equal "confirmed", @assumption.review_state
    assert_equal "6000.0", @assumption.params["amount"]
    assert_in_delta Time.current.to_f, @assumption.derived_at.to_f, 10
    assert_operator @plan.reload.current_plan_version, :>, version_before

    streams = css_select("turbo-stream").map { |s| s["target"] }
    assert_includes streams, "forecast_projection_region"
    assert_includes streams, ActionView::RecordIdentifier.dom_id(@assumption)
    assert_includes streams, "forecast_issues"
    assert_includes streams, "forecast_drawer_lock"
    assert_equal @assumption.lock_version.to_s,
      response.headers["X-Forecast-Assumption-Lock"]
  end

  test "accept enqueues the persist job with the reused snapshot and bumped plan version" do
    @payroll.update!(amount: -6_000)
    snapshot_id = @plan.forecast_projection_caches.current
      .order(created_at: :desc).first.forecast_source_snapshot_id

    post forecasts_assumption_resync_path(@assumption),
      params: { expected_lock_version: @assumption.lock_version.to_s },
      as: :turbo_stream

    assert_response :success
    assert_enqueued_with(
      job: ForecastProjectionPersistJob,
      args: [ @plan.id, snapshot_id, @plan.reload.current_plan_version, Date.current ]
    )
  end

  test "accept never trusts client-submitted derived values" do
    @payroll.update!(amount: -6_000)

    post forecasts_assumption_resync_path(@assumption),
      params: {
        expected_lock_version: @assumption.lock_version.to_s,
        amount: "999999", assumption: { amount: "999999" }
      },
      as: :turbo_stream

    assert_response :success
    assert_equal 6000, @assumption.reload.amount
  end

  test "accept with a stale lock version returns 409, does not write, and restreams server state" do
    @payroll.update!(amount: -6_000)

    post forecasts_assumption_resync_path(@assumption),
      params: { expected_lock_version: "99" },
      as: :turbo_stream

    assert_response :conflict
    assert_equal 5000, @assumption.reload.amount
    assert_equal "needs_review", @assumption.review_state
    streams = css_select("turbo-stream").map { |s| s["target"] }
    assert_includes streams, "forecast_projection_region"
    assert_includes streams, ActionView::RecordIdentifier.dom_id(@assumption)
    assert_includes streams, "forecast_drawer_lock"
  end

  test "accept when the source is gone is a no-write 422 with the source-gone card" do
    @payroll.destroy!

    assert_no_enqueued_jobs(only: ForecastProjectionPersistJob) do
      post forecasts_assumption_resync_path(@assumption),
        params: { expected_lock_version: @assumption.lock_version.to_s },
        as: :turbo_stream
    end

    assert_response :unprocessable_entity
    assert_equal 5000, @assumption.reload.amount
    assert_equal "needs_review", @assumption.review_state
    assert_includes response.body, I18n.t("forecasts.workspace.card.resync.source_gone")
  end

  test "accept is family-scoped" do
    sign_in users(:empty)
    post forecasts_assumption_resync_path(@assumption),
      params: { expected_lock_version: @assumption.lock_version.to_s },
      as: :turbo_stream
    assert_response :not_found
    assert_equal 5000, @assumption.reload.amount
  end

  test "accept clears a pre-seeded drift verdict and dismissed amount" do
    @payroll.update!(amount: -6_000)
    # Seeded the way the Task-5 scanner writes them: update_columns, so the
    # seeding itself never bumps lock_version.
    @assumption.update_columns(
      drift: {
        "status" => "drifted", "proposed_amount" => "6000.0",
        "current_amount" => "5000.0", "relative" => "0.2",
        "basis" => "source_rederive", "computed_at" => Time.current.iso8601
      },
      drift_dismissed_amount: 5_500
    )

    post forecasts_assumption_resync_path(@assumption),
      params: { expected_lock_version: @assumption.reload.lock_version.to_s },
      as: :turbo_stream

    assert_response :success
    @assumption.reload
    assert_equal 6000, @assumption.amount
    assert_nil @assumption.drift, "accepting must resolve the nudge"
    assert_nil @assumption.drift_dismissed_amount, "accept resets the soft-dismiss sentinel"
  end
end
