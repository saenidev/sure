require "test_helper"
require Rails.root.join("test/fixtures/files/forecasts/connected_family_proof")

# Slice C8: Forecasts::AssumptionsController#update — the salary save endpoint
# (PATCH /forecast/assumptions/:id).
#
# Proves the spec's "Live Recompute Model", "Recompute Job Contract", "Conflict
# Handling", "Patch budget", and "Save endpoints" rules for the save path:
#
#   - The save validates via SalaryForm (B14) with plan-version + lock_version
#     optimistic checks, persists in a transaction, and increments
#     forecast_plans.current_plan_version (spec "Live Recompute Model": "persists
#     the edit in a transaction, increments forecast_plans.current_plan_version").
#   - It runs recompute through the coordinator (B12) synchronously within budget,
#     or enqueues ForecastRecomputeJob + marks recomputing when over budget.
#   - It returns a TYPED changed-region payload (saved card summary,
#     selected-period inspector, metric strip, issue panel, freshness, chart data
#     token) + version tokens — NOT a full workspace reload (spec "Patch budget",
#     "Save endpoints").
#   - A stale plan version returns a conflict response preserving editor/period/
#     scenario context — no silent overwrite (spec "Conflict Handling").
#   - It is family-scoped (the assumption is resolved server-side through
#     Current.family, never from params) and gated behind the V2 feature check.
#   - It stays within the pre-engine query budget (<= 30 SQL).
class Forecasts::AssumptionsControllerUpdateTest < ActionDispatch::IntegrationTest
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

  # --- Happy path: save increments plan version + returns changed regions ---

  test "saving a salary edit increments the plan version" do
    with_v2_enabled do
      plan, salary = warm_plan_and_salary
      before_version = plan.current_plan_version

      patch forecast_assumption_url(salary), params: valid_salary_params(salary, plan)

      assert_response :success
      assert_equal before_version + 1, plan.reload.current_plan_version,
        "expected the save to increment forecast_plans.current_plan_version by 1"
    end
  end

  test "saving persists the edited assumption attributes" do
    with_v2_enabled do
      plan, salary = warm_plan_and_salary

      patch forecast_assumption_url(salary),
        params: valid_salary_params(salary, plan).merge(amount: "7500")

      assert_response :success
      assert_equal BigDecimal("7500"), salary.reload.amount
    end
  end

  test "returns a typed changed-region payload, not a full workspace reload" do
    with_v2_enabled do
      plan, salary = warm_plan_and_salary

      patch forecast_assumption_url(salary), params: valid_salary_params(salary, plan)

      assert_response :success
      assert_equal "application/json", response.media_type

      payload = response.parsed_body
      # The typed changed-region payload — the regions the spec's "Patch budget"
      # allows an assumption save to patch, plus version tokens. Explicitly NOT a
      # full workspace prop bag.
      assert payload.key?("saved_card"), "expected the saved card summary region"
      assert payload.key?("selected_period"), "expected the selected-period inspector region"
      assert payload.key?("metric_strip"), "expected the metric strip region"
      assert payload.key?("issues"), "expected the issue panel region"
      assert payload.key?("freshness"), "expected the freshness region"
      assert payload.key?("chart_data_token"), "expected the chart data token"
      assert payload.key?("version_tokens"), "expected version tokens"

      # NOT a full workspace reload (no first-viewport prop bag, no engine internals).
      refute payload.key?("plan"), "save must not return the full plan region"
      refute payload.key?("band"), "save must not return the full chart band region"
      refute payload.key?("assumptionGroups"), "save must not return the full assumption rail"
      refute payload.key?("packet")
      refute payload.key?("projection_result")
    end
  end

  test "version tokens carry the committed plan version and the saved assumption lock version" do
    with_v2_enabled do
      plan, salary = warm_plan_and_salary

      patch forecast_assumption_url(salary), params: valid_salary_params(salary, plan)
      assert_response :success

      tokens = response.parsed_body["version_tokens"]
      assert_equal plan.reload.current_plan_version, tokens["plan_version"]
      assert_equal salary.reload.lock_version, tokens["lock_version"]
    end
  end

  test "the saved card region reflects the committed server state, not client input" do
    with_v2_enabled do
      plan, salary = warm_plan_and_salary

      patch forecast_assumption_url(salary),
        params: valid_salary_params(salary, plan).merge(amount: "9000")
      assert_response :success

      card = response.parsed_body["saved_card"]
      assert_equal salary.id, card["id"]
      assert_equal "salary", card["kind"]
      assert_equal "9000.0", card.dig("amount_summary", "amount")
    end
  end

  # --- Living expense save: actualization_policy normalization --------------

  # Regression: LivingExpenseForm persists actualization_policy as a flat string
  # ("none"/"replace"/"offset"), but the living_expense expander reads it as a
  # typed hash. Before the packet-builder normalization + expander coercion, the
  # synchronous recompute on a living_expense PATCH raised an uncaught TypeError
  # (not InvalidExpansionError, which the engine rescues) and returned a 500.
  test "saving a living_expense edit recomputes without a 500" do
    with_v2_enabled do
      plan, living = warm_plan_and_living_expense

      patch forecast_assumption_url(living), params: valid_living_expense_params(living, plan)

      assert_response :success
      assert_equal "application/json", response.media_type
      assert_equal "fresh", response.parsed_body.dig("freshness", "state")
    end
  end

  test "saving a living_expense persists the flat actualization_policy" do
    with_v2_enabled do
      plan, living = warm_plan_and_living_expense

      patch forecast_assumption_url(living),
        params: valid_living_expense_params(living, plan).merge(actualization_policy: "offset")

      assert_response :success
      assert_equal "offset", living.reload.params["actualization_policy"]
    end
  end

  # --- Recompute: runs synchronously within budget --------------------------

  test "a within-budget save recomputes synchronously and returns fresh projection regions" do
    with_v2_enabled do
      plan, salary = warm_plan_and_salary

      # No background job for the small proof-slice plan (under SYNC_PERIOD_BUDGET).
      assert_no_enqueued_jobs only: ForecastRecomputeJob do
        patch forecast_assumption_url(salary), params: valid_salary_params(salary, plan)
      end
      assert_response :success

      # A fresh current cache for the NEW plan version exists after the sync recompute.
      cache = plan.forecast_projection_caches.current.where(status: "fresh")
        .order(finished_at: :desc).first
      assert_not_nil cache
      assert_equal plan.reload.current_plan_version, cache.plan_version

      assert_equal "fresh", response.parsed_body.dig("freshness", "state")
    end
  end

  # --- Recompute: over-budget path enqueues the job + marks recomputing -----

  test "an over-budget save enqueues ForecastRecomputeJob and returns recomputing projection state" do
    with_v2_enabled do
      plan, salary = warm_plan_and_salary

      # Force the over-budget branch: the coordinator reports the plan is too large
      # to recompute inline, so the controller defers to the background job.
      Forecasts::Projection::RecomputeCoordinator
        .any_instance.stubs(:recompute_synchronously?).returns(false)

      assert_enqueued_with(job: ForecastRecomputeJob) do
        patch forecast_assumption_url(salary), params: valid_salary_params(salary, plan)
      end
      assert_response :success

      # The card still saved (committed plan version bumped) and the projection
      # region shows recomputing — the spec's "saved card + stale/recomputing"
      # over-budget contract.
      assert_equal "recomputing", response.parsed_body.dig("freshness", "state")
      assert_equal plan.current_plan_version + 1, plan.reload.current_plan_version
    end
  end

  test "the enqueued ForecastRecomputeJob is keyed by the recompute job contract" do
    with_v2_enabled do
      plan, salary = warm_plan_and_salary

      Forecasts::Projection::RecomputeCoordinator
        .any_instance.stubs(:recompute_synchronously?).returns(false)

      patch forecast_assumption_url(salary), params: valid_salary_params(salary, plan)
      assert_response :success

      enqueued = enqueued_jobs.find { |job| job["job_class"] == "ForecastRecomputeJob" }
      assert_not_nil enqueued, "expected a ForecastRecomputeJob to be enqueued"

      args = enqueued["arguments"].first
      args = args.transform_keys(&:to_s) if args.respond_to?(:transform_keys)
      assert_equal plan.id, args["forecast_plan_id"]
      assert_equal plan.reload.current_plan_version, args["plan_version"]
    end
  end

  # --- Conflict handling: stale plan version --------------------------------

  test "a stale plan version returns a conflict and does not overwrite" do
    with_v2_enabled do
      plan, salary = warm_plan_and_salary

      # Simulate a concurrent commit: the live plan version moves ahead of the
      # version the editor observed.
      observed_version = plan.current_plan_version
      plan.update!(current_plan_version: observed_version + 5)

      patch forecast_assumption_url(salary),
        params: valid_salary_params(salary, plan)
          .merge(plan_version: observed_version, amount: "12345")

      assert_response :conflict
      # No silent overwrite: the assumption is unchanged and the version did not
      # advance off the concurrent commit.
      refute_equal BigDecimal("12345"), salary.reload.amount
      assert_equal observed_version + 5, plan.reload.current_plan_version
    end
  end

  test "a conflict response preserves the editor / period / scenario context" do
    with_v2_enabled do
      plan, salary = warm_plan_and_salary

      observed_version = plan.current_plan_version
      plan.update!(current_plan_version: observed_version + 1)

      patch forecast_assumption_url(salary),
        params: valid_salary_params(salary, plan).merge(plan_version: observed_version)

      assert_response :conflict
      payload = response.parsed_body
      assert_equal "stale_plan_version", payload["conflict"]
      context = payload["context"]
      assert_equal salary.id, context["assumption_id"]
      assert context.key?("scenario_layer_id")
      assert_equal plan.reload.current_plan_version, context["plan_version"]
    end
  end

  test "a stale assumption lock_version keeps the editor open with a conflict" do
    with_v2_enabled do
      plan, salary = warm_plan_and_salary

      patch forecast_assumption_url(salary),
        params: valid_salary_params(salary, plan).merge(expected_lock_version: salary.lock_version + 9)

      assert_response :conflict
      assert_equal salary.lock_version, salary.reload.lock_version,
        "the assumption must not be saved on a stale lock_version"
    end
  end

  # --- Validation: invalid input --------------------------------------------

  test "an invalid edit returns a 422 with typed field errors and does not save" do
    with_v2_enabled do
      plan, salary = warm_plan_and_salary
      before_version = plan.current_plan_version

      patch forecast_assumption_url(salary),
        params: valid_salary_params(salary, plan).merge(amount: "-50")

      assert_response :unprocessable_entity
      payload = response.parsed_body
      assert payload["errors"].is_a?(Hash)
      assert_equal "not_positive", payload.dig("errors", "amount")
      assert_equal before_version, plan.reload.current_plan_version,
        "an invalid save must not increment the plan version"
    end
  end

  # Regression (F6): every stable field error code the form emits must resolve to
  # localized client copy under forecasts.editor.errors.<code>, never the raw key
  # string. unknown_currency / not_permitted were previously emitted by the form
  # but absent from that map, so the React drawer surfaced the literal
  # "forecasts.editor.errors.unknown_currency".
  test "an unsupported currency returns a localizable unknown_currency field error" do
    with_v2_enabled do
      plan, salary = warm_plan_and_salary

      patch forecast_assumption_url(salary),
        params: valid_salary_params(salary, plan).merge(currency: "ZZZ")

      assert_response :unprocessable_entity
      code = response.parsed_body.dig("errors", "currency")
      assert_equal "unknown_currency", code
      assert_localized_editor_error(code)
    end
  end

  test "an inaccessible category returns a localizable not_permitted field error" do
    with_v2_enabled do
      plan, living = warm_plan_and_living_expense

      # A category that belongs to another family is not in family.categories, so the
      # form records a not_permitted reference error rather than persisting it.
      other_family = users(:empty).family
      refute_equal @family.id, other_family.id, "fixture sanity: distinct families"
      foreign_category = other_family.categories.create!(name: "Foreign")

      patch forecast_assumption_url(living),
        params: valid_living_expense_params(living, plan).merge(category_ids: [ foreign_category.id ])

      assert_response :unprocessable_entity
      code = response.parsed_body.dig("errors", "category_ids")
      assert_equal "not_permitted", code
      assert_localized_editor_error(code)
    end
  end

  # --- Family scoping -------------------------------------------------------

  test "never trusts a family_id param: saving another family's assumption 404s" do
    with_v2_enabled do
      plan, salary = warm_plan_and_salary

      other_user = users(:empty)
      refute_equal @family.id, other_user.family_id, "fixture sanity: distinct families"
      sign_in other_user

      with_v2_enabled_for(other_user.family) do
        patch forecast_assumption_url(salary),
          params: valid_salary_params(salary, plan).merge(family_id: @family.id)
        assert_response :not_found
        refute_equal BigDecimal("99999"), salary.reload.amount
      end
    end
  end

  test "an unknown assumption id 404s" do
    with_v2_enabled do
      warm_plan_and_salary

      patch forecast_assumption_url("00000000-0000-0000-0000-000000000000"),
        params: { kind: "salary" }
      assert_response :not_found
    end
  end

  # --- Gating ---------------------------------------------------------------

  test "is gated behind the V2 feature check" do
    # Build the plan + salary directly (no HTTP): with the V2 flag off, /forecast
    # renders V1 and would not create a V2 plan.
    plan = Forecasts::DefaultPlanBuilder.new(family: @family, as_of: Date.current).build
    salary = plan.forecast_assumptions.for_kind("salary").first

    # V2 flag off: the endpoint must not serve the V2 save.
    patch forecast_assumption_url(salary), params: valid_salary_params(salary, plan)
    assert_response :not_found
  end

  # --- Query budget ---------------------------------------------------------

  test "the save stays within the pre-engine query budget" do
    with_v2_enabled do
      plan, salary = warm_plan_and_salary

      # Skip the engine + persistence so we measure only the controller's
      # pre-engine work (validation, load, version increment) against the budget.
      Forecasts::Projection::RecomputeCoordinator
        .any_instance.stubs(:recompute_synchronously?).returns(false)

      query_count = count_select_queries do
        patch forecast_assumption_url(salary), params: valid_salary_params(salary, plan)
        assert_response :success
      end

      assert query_count <= 30,
        "expected <= 30 SQL SELECTs for a save (pre-engine), got #{query_count}"
    end
  end

  private
    # Asserts a stable field error code resolves to localized client copy under
    # forecasts.editor.errors.<code> (the key the React drawer localizes via
    # ft("forecasts.editor.errors.<code>")) — i.e. the user sees real copy, never
    # the raw key string. Guards against a code the form emits but the editor copy
    # table omits (F6).
    def assert_localized_editor_error(code)
      key = "forecasts.editor.errors.#{code}"
      assert I18n.exists?(key),
        "expected localized client copy for error code #{code.inspect} at #{key}"
      message = I18n.t(key)
      assert message.present?, "localized message for #{key} must not be blank"
      refute_equal key, message,
        "error code #{code.inspect} surfaced the raw i18n key instead of localized copy"
    end

    # Opens the workspace once (load-or-create plan + ensure fresh cache via the
    # shared loading seam) so the salary assumption + a current cache exist, then
    # returns [plan, salary_assumption].
    def warm_plan_and_salary
      get forecast_url
      assert_response :success
      plan = Forecasts::Plan.where(family: @family).sole
      salary = plan.forecast_assumptions.for_kind("salary").first
      [ plan, salary ]
    end

    # Same warm-up, but returns the source-derived living_expense assumption the
    # default plan builds from the connected budget.
    def warm_plan_and_living_expense
      get forecast_url
      assert_response :success
      plan = Forecasts::Plan.where(family: @family).sole
      living = plan.forecast_assumptions.for_kind("living_expense").first
      assert_not_nil living, "expected a source-derived living_expense assumption"
      [ plan, living ]
    end

    # A full, valid LivingExpenseForm param set: the required typed fields the
    # form coerces + validates (note actualization_policy is a flat string),
    # anchored on the current plan/lock versions for the optimistic checks.
    def valid_living_expense_params(living, plan)
      {
        kind: "living_expense",
        name: living.name,
        amount: living.amount.to_s,
        currency: living.currency || "USD",
        frequency: "monthly",
        inflation_policy: "flat",
        actualization_policy: "none",
        category_ids: [],
        expected_lock_version: living.lock_version,
        plan_version: plan.current_plan_version
      }
    end

    # A full, valid SalaryForm param set for the given salary assumption: the
    # required typed fields the form coerces + validates, anchored on the current
    # plan/lock versions for the optimistic checks.
    def valid_salary_params(salary, plan)
      {
        kind: "salary",
        name: salary.name,
        amount: salary.amount.to_s,
        currency: salary.currency || "USD",
        person_key: "primary",
        gross_or_net: "gross",
        frequency: "annual",
        growth_policy: "flat",
        expected_lock_version: salary.lock_version,
        plan_version: plan.current_plan_version
      }
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
