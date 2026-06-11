# frozen_string_literal: true

require "test_helper"

class Forecasts::AssumptionsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @user = users(:family_admin)
    @family = @user.family
    @plan = Forecasts::WorkspaceLoader.new(family: @family, today: Date.current).load.plan
    @assumption = @plan.forecast_assumptions.create!(
      family: @family, kind: "salary", name: "Salary", status: :active,
      amount: 5200, currency: "USD",
      params: { "frequency" => "monthly", "growth_policy" => "flat" }
    )
  end

  test "edit renders the drawer in the modal frame" do
    get edit_forecasts_assumption_path(@assumption), headers: { "Turbo-Frame" => "modal" }
    assert_response :success
    assert_select "turbo-frame#modal", count: 1
    assert_select "form[action=?]", forecasts_assumption_path(@assumption)
    assert_select "input[name=?]", "assumption[expected_lock_version]"
  end

  test "edit is family-scoped" do
    sign_in users(:empty)
    get edit_forecasts_assumption_path(@assumption)
    assert_response :not_found
  end

  test "update saves, recomputes, and streams the projection region, card, and issues" do
    patch forecasts_assumption_path(@assumption),
      params: { assumption: salary_params(amount: "6000") },
      as: :turbo_stream

    assert_response :success
    assert_equal 6000, @assumption.reload.amount
    assert_operator @assumption.forecast_plan.reload.current_plan_version, :>, 1

    streams = css_select("turbo-stream").map { |s| s["target"] }
    assert_includes streams, "forecast_projection_region"
    assert_includes streams, ActionView::RecordIdentifier.dom_id(@assumption)
    assert_includes streams, "forecast_issues"
  end

  test "update streams the projection rendered from the in-memory result" do
    patch forecasts_assumption_path(@assumption),
      params: { assumption: salary_params(amount: "6000") },
      as: :turbo_stream

    assert_response :success
    island_json = response.body[%r{<script type="application/json" id="forecast-island">(.*?)</script>}m, 1]
    assert island_json.present?, "projection region stream must embed the data island"
    island = JSON.parse(island_json)

    assert_equal @plan.reload.current_plan_version, island.dig("plan", "version")

    ordinal = island["assumptions"].index { |a| a["id"] == @assumption.id }
    assert ordinal, "island must list the edited assumption"
    assert island["periods"].any? { |p| p["aa"].include?(ordinal) },
      "periods must reference the edited assumption — the persisted cache predates it, " \
      "so this only holds when the stream rendered from the fresh in-memory result"
  end

  test "update enqueues the persist job with the reused snapshot and bumped plan version" do
    snapshot_id = @plan.forecast_projection_caches.current
      .order(created_at: :desc).first.forecast_source_snapshot_id

    patch forecasts_assumption_path(@assumption),
      params: { assumption: salary_params(amount: "6000") },
      as: :turbo_stream

    assert_response :success
    assert_enqueued_with(
      job: ForecastProjectionPersistJob,
      args: [ @plan.id, snapshot_id, @plan.reload.current_plan_version, Date.current ]
    )
  end

  test "performing the enqueued persist job writes the new projection cache" do
    patch forecasts_assumption_path(@assumption),
      params: { assumption: salary_params(amount: "6000") },
      as: :turbo_stream
    assert_response :success

    perform_enqueued_jobs(only: ForecastProjectionPersistJob)

    cache = @plan.forecast_projection_caches.current.order(created_at: :desc).first
    assert cache.fresh?
    assert_equal @plan.reload.current_plan_version, cache.plan_version
    assert cache.forecast_projection_periods.where(granularity: "month")
      .any? { |period| (period.active_assumption_ids || []).include?(@assumption.id) },
      "persisted periods must reference the edited assumption"
  end

  test "update with an invalid amount returns 422 and streams the form errors" do
    patch forecasts_assumption_path(@assumption),
      params: { assumption: salary_params(amount: "-5") },
      as: :turbo_stream

    assert_response :unprocessable_entity
    assert_equal 5200, @assumption.reload.amount
    streams = css_select("turbo-stream").map { |s| s["target"] }
    assert_includes streams, "forecast_drawer_form"
  end

  test "update with a stale lock version returns 409 and does not save" do
    patch forecasts_assumption_path(@assumption),
      params: { assumption: salary_params(amount: "6000", expected_lock_version: "99") },
      as: :turbo_stream

    assert_response :conflict
    assert_equal 5200, @assumption.reload.amount
  end

  test "successful update streams a refreshed lock token so the drawer can keep saving" do
    patch forecasts_assumption_path(@assumption),
      params: { assumption: salary_params(amount: "6000") },
      as: :turbo_stream

    assert_response :success
    assert_select "turbo-stream[target=forecast_drawer_lock] input[value=?]",
      @assumption.reload.lock_version.to_s
  end

  test "a stale lock restreams the server state alongside the 409" do
    patch forecasts_assumption_path(@assumption),
      params: { assumption: salary_params(amount: "6000", expected_lock_version: "99") },
      as: :turbo_stream

    assert_response :conflict
    streams = css_select("turbo-stream").map { |s| s["target"] }
    assert_includes streams, "forecast_drawer_form"
    assert_includes streams, "forecast_projection_region"
  end

  test "update is family-scoped" do
    sign_in users(:empty)
    patch forecasts_assumption_path(@assumption),
      params: { assumption: salary_params(amount: "1") },
      as: :turbo_stream
    assert_response :not_found
    assert_equal 5200, @assumption.reload.amount
  end

  private
    def salary_params(overrides = {})
      {
        name: "Salary",
        amount: "5200",
        currency: "USD",
        # person_key and gross_or_net are required by SalaryForm
        # (validate_required_fields) — without them every save 422s.
        person_key: "primary",
        gross_or_net: "net",
        frequency: "monthly",
        growth_policy: "flat",
        expected_lock_version: @assumption.reload.lock_version.to_s
      }.merge(overrides)
    end
end
