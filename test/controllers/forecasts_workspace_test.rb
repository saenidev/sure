# frozen_string_literal: true

require "test_helper"

class ForecastsWorkspaceTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @user = users(:family_admin)
  end

  test "GET /forecast bootstraps a plan and renders the workspace" do
    assert_difference -> { @user.family.forecast_plans.count }, 1 do
      get forecast_path
    end
    assert_response :success
    assert_select "#forecast_workspace"
    assert_select "#forecast-island", count: 1
    assert_select "#forecast_assumption_rail"
    assert_select "[data-controller=forecast-chart]"
  end

  test "workspace page wires the undo toast container with locale-derived labels" do
    get forecast_path
    assert_response :success
    # raise_on_missing_translations is OFF in the test env: a typoed
    # forecasts.workspace.editor.* key would render a "translation missing"
    # span and stay green without these explicit value assertions.
    assert_select "#forecast_undo_toast[data-controller=?]", "forecast-undo-toast"
    assert_select "#forecast_undo_toast[data-forecast-undo-toast-undo-label-value=?]", "Undo"
    assert_select "#forecast_undo_toast[data-forecast-undo-toast-saved-template-value=?]", "%{name} saved"
  end

  test "GET /forecast never renders V1 generate affordances" do
    get forecast_path
    assert_response :success
    assert_select "form[action=?]", "/forecast/runs", count: 0
  end

  test "GET /forecast runs no engine work when the cache is current" do
    get forecast_path # first load computes
    plan = @user.family.forecast_plans.first
    cache_id = plan.forecast_projection_caches.first.id

    get forecast_path
    assert_response :success
    assert_equal cache_id, plan.reload.forecast_projection_caches.first.id
  end

  test "GET /forecast enqueues a drift scan when the stored key is stale" do
    get forecast_path
    assert_response :success

    plan = @user.family.forecast_plans.first
    assert_nil plan.drift_scan_key, "no scan has run yet"
    assert_enqueued_with(
      job: ForecastDriftScanJob,
      args: [ plan.id, Forecasts::Drift.scan_key(plan) ]
    )
  end

  test "GET /forecast does not enqueue a drift scan when the key is current" do
    get forecast_path # bootstrap plan + cache (enqueues the first scan)
    plan = @user.family.forecast_plans.first
    plan.update_columns(drift_scan_key: Forecasts::Drift.scan_key(plan))

    assert_no_enqueued_jobs(only: ForecastDriftScanJob) do
      get forecast_path
    end
    assert_response :success
  end

  test "a drifted assumption renders the localized nudge with accept and dismiss controls" do
    plan = Forecasts::WorkspaceLoader.new(family: @user.family, today: Date.current).load.plan
    assumption = plan.forecast_assumptions.create!(
      family: @user.family, kind: "salary", name: "Drifty Salary", status: :active,
      amount: 1100, currency: "USD",
      params: { "frequency" => "monthly", "growth_policy" => "flat" }
    )
    assumption.update_columns(drift: {
      "status" => "drifted", "proposed_amount" => "1340.0", "current_amount" => "1100.0",
      "relative" => "0.218", "basis" => "source_rederive",
      "computed_at" => Time.current.iso8601
    })

    get forecast_path

    assert_response :success
    card = "##{ActionView::RecordIdentifier.dom_id(assumption)}"
    assert_select "#{card} [role=status] p",
      text: /“Drifty Salary”: \$1,100\.00 → \$1,340\.00\?/
    assert_select "#{card} form[action=?]",
      forecasts_assumption_resync_path(assumption), count: 1
    assert_select "#{card} form[action=?] input[name=expected_lock_version]",
      forecasts_assumption_resync_path(assumption)
    assert_select "#{card} form[action=?]",
      forecasts_assumption_drift_dismissal_path(assumption), count: 2
  end
end
