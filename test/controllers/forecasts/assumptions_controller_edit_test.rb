require "test_helper"
require Rails.root.join("test/fixtures/files/forecasts/connected_family_proof")

# Slice C7: Forecasts::AssumptionsController#edit — the typed editor-drawer open
# endpoint (GET /forecast/assumptions/:id/edit).
#
# Proves the spec's "Editor Contracts" / "Inertia And JSON Endpoints" rule for the
# editor-open path: GET /forecast/assumptions/:id/edit returns ONE
# EditorPrefillReadModel (B13) typed payload for a single assumption — the form
# key, current values, collapsed-section summaries, and validation metadata
# (lock_version for stale-edit detection) — and NOTHING else (no other
# assumptions, no chart series, no projection-result bodies). It is family-scoped
# (the assumption is resolved server-side through Current.family, never from
# params), gated behind the V2 feature check, and stays within a tight query
# budget (the editor open is a single-record read, not a workspace reload).
#
# Spec: "V2 route shape" (GET /forecast/assumptions/:id/edit), "Editor Contracts"
# (open from a card; preserve plan/scenario/period; typed payload), "Read Model
# Contracts" / "EditorPrefillReadModel" (one typed editor payload, not a full plan
# payload), "Inertia And JSON Endpoints" (editor open returns one
# EditorPrefillReadModel, not a full plan payload), "Query And Data-Loading
# Budgets".
class Forecasts::AssumptionsControllerEditTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @family = @user.family

    Forecasts::ConnectedFamilyProof.build(
      family: @family,
      depository_account: accounts(:depository),
      budget: budgets(:one),
      as_of: Date.current
    )

    sign_in @user
  end

  # --- Happy path: typed EditorPrefillReadModel payload --------------------

  test "returns the EditorPrefillReadModel payload for a salary assumption" do
    with_v2_enabled do
      salary = salary_assumption

      get edit_forecast_assumption_url(salary)

      assert_response :success
      assert_equal "application/json", response.media_type

      payload = response.parsed_body
      assert_equal "salary", payload["form_key"]
      assert_equal salary.id, payload["assumption_id"]
      assert payload.key?("scenario_layer_id")
      assert payload["primary_values"].is_a?(Hash)
      assert payload["section_summaries"].is_a?(Hash)
      assert payload["validation"].is_a?(Hash)
    end
  end

  test "carries the optimistic lock_version in validation metadata for stale-edit detection" do
    with_v2_enabled do
      salary = salary_assumption

      get edit_forecast_assumption_url(salary)
      assert_response :success

      validation = response.parsed_body["validation"]
      assert_equal salary.lock_version, validation["lock_version"]
      assert validation["schema_version"].present?
    end
  end

  test "primary values expose the assumption's current editable fields" do
    with_v2_enabled do
      salary = salary_assumption

      get edit_forecast_assumption_url(salary)
      assert_response :success

      primary = response.parsed_body["primary_values"]
      assert_equal salary.name, primary["name"]
      assert_equal salary.amount.to_s, primary["amount"]
      assert_equal salary.currency, primary["currency"]
      assert primary.key?("params")
    end
  end

  # --- Family scoping ------------------------------------------------------

  test "never trusts a family_id param: an assumption from another family 404s" do
    with_v2_enabled do
      salary = salary_assumption

      other_user = users(:empty)
      refute_equal @family.id, other_user.family_id, "fixture sanity: distinct families"
      sign_in other_user

      with_v2_enabled_for(other_user.family) do
        # Even passing the original family_id must not widen scope — the
        # controller resolves the assumption through Current.family only.
        get edit_forecast_assumption_url(salary), params: { family_id: @family.id }
        assert_response :not_found
      end
    end
  end

  test "an unknown assumption id 404s" do
    with_v2_enabled do
      salary_assumption # ensure the plan exists

      get edit_forecast_assumption_url("00000000-0000-0000-0000-000000000000")
      assert_response :not_found
    end
  end

  # --- Boundaries: one typed editor payload, not a full plan payload -------

  test "returns one typed editor payload, not a full plan payload or engine internals" do
    with_v2_enabled do
      salary = salary_assumption

      get edit_forecast_assumption_url(salary)
      assert_response :success

      payload = response.parsed_body
      # The typed EditorPrefillReadModel shape — and explicitly NOT a full plan
      # payload, chart series, projection-result bodies, or engine internals.
      assert_equal(
        %w[form_key assumption_id scenario_layer_id primary_values section_summaries validation].sort,
        payload.keys.sort
      )
      refute payload.key?("plan")
      refute payload.key?("band")
      refute payload.key?("assumptionGroups")
      refute payload.key?("series")
      refute payload.key?("projection_result")
      refute payload.key?("packet")
    end
  end

  # --- Query budget --------------------------------------------------------

  test "editor open stays within the query budget" do
    with_v2_enabled do
      salary = salary_assumption

      query_count = count_select_queries do
        get edit_forecast_assumption_url(salary)
        assert_response :success
      end

      assert query_count <= 15,
        "expected <= 15 SQL queries for an editor-open load, got #{query_count}"
    end
  end

  # --- Gating --------------------------------------------------------------

  test "is gated behind the V2 feature check" do
    salary = salary_assumption

    # V2 flag off: the endpoint must not serve V2 editor JSON.
    get edit_forecast_assumption_url(salary)
    assert_response :not_found
  end

  private
    # Builds the default plan (load-or-create) and returns its source-derived
    # salary assumption — the one interactive editor in the MVP.
    def salary_assumption
      @salary_assumption ||= begin
        plan = Forecasts::DefaultPlanBuilder.new(family: @family, as_of: Date.current).build
        plan.forecast_assumptions.for_kind("salary").first
      end
    end

    def with_v2_enabled(&block)
      with_v2_enabled_for(@family, &block)
    end

    def with_v2_enabled_for(family)
      original_enabled = Rails.configuration.x.forecast_v2.enabled
      original_ids = Rails.configuration.x.forecast_v2.family_ids
      Rails.configuration.x.forecast_v2.enabled = true
      Rails.configuration.x.forecast_v2.family_ids = [ family.id.to_s ].to_set.freeze
      yield
    ensure
      Rails.configuration.x.forecast_v2.enabled = original_enabled
      Rails.configuration.x.forecast_v2.family_ids = original_ids
    end

    def count_select_queries
      queries = []
      callback = lambda do |_name, _start, _finish, _id, payload|
        sql = payload[:sql]
        next if sql.nil?
        next if payload[:name].to_s.include?("SCHEMA")
        queries << sql if sql.match?(/SELECT/)
      end
      ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { yield }
      queries.size
    end
end
