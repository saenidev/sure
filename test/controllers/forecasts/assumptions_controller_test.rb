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

  test "successful update exposes the fresh lock version in the assumption-lock header" do
    patch forecasts_assumption_path(@assumption),
      params: { assumption: salary_params(amount: "6000") },
      as: :turbo_stream

    assert_response :success
    assert_equal @assumption.reload.lock_version.to_s,
      response.headers["X-Forecast-Assumption-Lock"]
  end

  test "update streams an island whose packet-lite previews the edited card" do
    patch forecasts_assumption_path(@assumption),
      params: { assumption: salary_params(amount: "6000") },
      as: :turbo_stream

    assert_response :success
    island_json = response.body[%r{<script type="application/json" id="forecast-island">(.*?)</script>}m, 1]
    assert island_json.present?, "projection region stream must embed the data island"
    island = JSON.parse(island_json)

    entry = island.dig("packet", "assumptions")&.find { |a| a["id"] == @assumption.id }
    assert entry, "packet-lite must carry the edited assumption"
    assert_equal true, entry["pv"]
    # PacketBuilder serializes money via BigDecimal#to_s("F") — 6000 -> "6000.0".
    assert_equal "6000.0", entry.dig("params", "amount")
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

  test "update keeps the save and omits projection streams when compute fails with no cache" do
    @plan.forecast_projection_caches.destroy_all
    Forecasts::Projection::RecomputeCoordinator.any_instance
      .stubs(:compute).raises(StandardError, "engine exploded")

    patch forecasts_assumption_path(@assumption),
      params: { assumption: salary_params(amount: "6000") },
      as: :turbo_stream

    assert_response :success
    assert_equal 6000, @assumption.reload.amount

    streams = css_select("turbo-stream").map { |s| s["target"] }
    assert_includes streams, ActionView::RecordIdentifier.dom_id(@assumption)
    assert_includes streams, "forecast_drawer_lock"
    assert_not_includes streams, "forecast_projection_region",
      "nothing to refresh — no result and no cache must not stream the projection region"
    assert_not_includes streams, "forecast_issues"
  end

  # Production repro: the drawer partials submit only a SUBSET of the form's
  # required params (name/amount/currency/frequency/policy/lock). A save of a
  # real source-DERIVED row must succeed — unsubmitted fields fall back to the
  # assumption's stored values, never to blank.
  test "update saves a partial drawer submit for a derived salary" do
    @family.recurring_transactions.create!(
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
    Forecasts::DefaultPlanBuilder.new(family: @family, as_of: Date.current).build
    derived = @plan.forecast_assumptions.where(kind: "salary", origin: "source_derived").sole

    patch forecasts_assumption_path(derived),
      params: { assumption: {
        name: derived.name,
        amount: "6500",
        currency: derived.currency,
        frequency: "monthly",
        growth_policy: "flat",
        expected_lock_version: derived.lock_version.to_s
      } },
      as: :turbo_stream

    assert_response :success
    assert_equal 6500, derived.reload.amount
    # The unsubmitted required params survive the partial save.
    assert_equal "primary", derived.params["person_key"]
    assert_equal "net", derived.params["gross_or_net"]
  end

  test "update saves a partial drawer submit for a derived living expense" do
    derived = @plan.forecast_assumptions.where(kind: "living_expense", origin: "source_derived").sole

    patch forecasts_assumption_path(derived),
      params: { assumption: {
        name: derived.name,
        amount: "3100",
        currency: derived.currency,
        frequency: "monthly",
        inflation_policy: "flat",
        expected_lock_version: derived.lock_version.to_s
      } },
      as: :turbo_stream

    assert_response :success
    assert_equal 3100, derived.reload.amount
    # The unsubmitted required actualization_policy survives the partial save.
    assert_equal "none", derived.params["actualization_policy"]
  end

  test "update is family-scoped" do
    sign_in users(:empty)
    patch forecasts_assumption_path(@assumption),
      params: { assumption: salary_params(amount: "1") },
      as: :turbo_stream
    assert_response :not_found
    assert_equal 5200, @assumption.reload.amount
  end

  # A manual edit invalidates any cached drift verdict — its "current_amount"
  # no longer matches the saved figure — so the save must drop the cached
  # verdict and the soft-dismiss sentinel; the next scan re-evaluates fresh.
  test "update clears a stale cached drift verdict and dismissed amount" do
    @assumption.update_columns(
      drift: {
        "status" => "drifted", "proposed_amount" => "6500.0",
        "current_amount" => "5200.0", "relative" => "0.25",
        "basis" => "source_rederive", "computed_at" => Time.current.iso8601
      },
      drift_dismissed_amount: 6_400
    )

    patch forecasts_assumption_path(@assumption),
      params: { assumption: salary_params(amount: "6000") },
      as: :turbo_stream

    assert_response :success
    @assumption.reload
    assert_equal 6000, @assumption.amount
    assert_nil @assumption.drift, "an explicit edit must invalidate the cached drift verdict"
    assert_nil @assumption.drift_dismissed_amount, "an explicit edit must reset the soft-dismiss sentinel"
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
