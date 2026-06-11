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
end
