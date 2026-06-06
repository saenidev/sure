# frozen_string_literal: true

module Forecasts
  # Forecast V2 default plan builder. When a family opens `/forecast` and has no
  # active V2 plan, this application service creates exactly one active
  # `Forecasts::Plan` and derives baseline assumptions with provenance from the
  # family's connected Sure data:
  #
  #   - a `salary` assumption from a recurring payroll deposit, and
  #   - a `living_expense` assumption from the current budget (preferred) or a
  #     recurring-spending average fallback.
  #
  # Derivation is the bridge between Sure's connected-finance data and the plan
  # workspace; it is NOT part of the pure projection engine. This is a PORO that
  # reads ActiveRecord and writes editable assumptions carrying provenance
  # (origin, confidence, review_state, source_refs, derived_at, derivation_version)
  # so the UI can prompt for review. See spec "Default Plan Derivation",
  # "Bootstrap Rules", "Source-To-Assumption Mapping", "Derivation Confidence".
  #
  # The build is idempotent (spec "Bootstrap Rules"): reopening `/forecast` must
  # not duplicate plans or assumptions. Plans are keyed by "the family has no
  # active V2 plan". Most derived assumptions are keyed by `(family, source
  # record)`; the living_expense derivation can switch sources between reopens
  # (budget -> recurring transaction), so it is additionally keyed by derivation
  # purpose `(family, plan, kind, source_derived)` to avoid double-counting.
  #
  # Family-scoping is anchored to the family passed in by the caller (which is
  # always `Current.family` at the call site). The builder never reads another
  # family's data and never trusts a family_id from arbitrary params.
  class DefaultPlanBuilder
    DERIVATION_VERSION = "forecast-derivation-v1"
    DEFAULT_HORIZON_MONTHS = 36
    DEFAULT_PLAN_NAME = "Baseline plan"

    attr_reader :family, :as_of

    def initialize(family:, as_of:)
      raise ArgumentError, "family is required" if family.nil?
      raise ArgumentError, "as_of is required" if as_of.nil?

      @family = family
      @as_of = as_of.to_date
    end

    # Returns the family's active Forecasts::Plan, creating it (with derived
    # baseline assumptions) on first call. Idempotent: subsequent calls reuse the
    # existing plan and never duplicate plans or per-source assumptions.
    def build
      existing = family.forecast_plans.active.ordered.first
      return ensure_baseline_assumptions(existing) if existing

      Forecasts::Plan.transaction do
        plan = create_plan!
        ensure_baseline_assumptions(plan)
        plan
      end
    end

    private
      def create_plan!
        family.forecast_plans.create!(
          name: DEFAULT_PLAN_NAME,
          status: :active,
          horizon_start_on: as_of,
          horizon_end_on: as_of >> DEFAULT_HORIZON_MONTHS,
          reporting_currency: reporting_currency
        )
      end

      # Derives the baseline assumptions, each guarded by its source-record key so
      # reopening the plan is a no-op. Returns the plan for chaining.
      def ensure_baseline_assumptions(plan)
        derive_salary(plan)
        derive_living_expense(plan)
        plan
      end

      # --- Salary (from recurring payroll deposit) ------------------------------

      # A recurring payroll deposit is an active, non-transfer recurring inflow
      # (negative amount under Sure's sign convention). The most significant one
      # (largest magnitude) becomes a reviewable `salary` assumption. Confidence
      # is medium per "Source-To-Assumption Mapping": ask the user to confirm
      # earner, gross/net interpretation, and end anchor.
      def derive_salary(plan)
        deposit = primary_payroll_deposit
        return if deposit.nil?

        upsert_derived_assumption(
          plan: plan,
          kind: "salary",
          name: salary_name(deposit),
          amount: income_magnitude(deposit),
          currency: deposit.currency,
          confidence: "medium",
          source_record: deposit,
          params: { "annual_gross" => nil, "interpretation" => "unconfirmed" }
        )
      end

      def primary_payroll_deposit
        @primary_payroll_deposit ||= family.recurring_transactions
          .where(status: "active", destination_account_id: nil)
          .where("amount < 0")
          .to_a
          .max_by { |recurring| income_magnitude(recurring) }
      end

      def salary_name(deposit)
        deposit.name.presence || deposit.merchant&.name.presence || "Salary"
      end

      # Income is stored as a negative recurring amount; expose it as a positive
      # salary figure.
      def income_magnitude(recurring)
        to_decimal(recurring.amount).abs
      end

      # --- Living expense (from budget, else spending average) ------------------

      # Prefer current Sure budget intent over a transaction average (spec
      # "Source-To-Assumption Mapping" / derivation precedence). When no current
      # budget exists, fall back to the largest recurring outflow as a spending
      # source. Either way the assumption is medium-confidence and needs review.
      #
      # Idempotency here is by derivation purpose, not just the specific source
      # record: the source can legitimately *change* between reopens (e.g. the
      # first load derives from a budget, a later load runs after the budget
      # window or after the budget is deleted and would derive from a recurring
      # transaction). Keying only on `(source_record_type, source_record_id)`
      # would let the new source spawn a SECOND living_expense and double-count
      # spending. The spec ("Bootstrap Rules") requires reopening to never create
      # duplicate assumptions, so we short-circuit when the plan already carries a
      # source-derived living_expense from any source.
      def derive_living_expense(plan)
        return if existing_source_derived?(plan, "living_expense")

        budget = current_budget
        if budget
          upsert_derived_assumption(
            plan: plan,
            kind: "living_expense",
            name: "Living expenses",
            amount: to_decimal(budget.budgeted_spending),
            currency: budget.currency,
            confidence: "medium",
            source_record: budget,
            params: { "basis" => "budget", "inflation_rate" => nil }
          )
          return
        end

        spend = primary_recurring_expense
        return if spend.nil?

        upsert_derived_assumption(
          plan: plan,
          kind: "living_expense",
          name: spend.name.presence || "Living expenses",
          amount: to_decimal(spend.amount).abs,
          currency: spend.currency,
          confidence: "medium",
          source_record: spend,
          params: { "basis" => "recurring_average", "inflation_rate" => nil }
        )
      end

      # Current budget: the budget whose period contains as_of, falling back to the
      # latest budget that has started on or before as_of.
      def current_budget
        @current_budget ||= begin
          # `id ASC` is a deterministic final tiebreaker: two budgets sharing the
          # latest start_date would otherwise be picked nondeterministically, so
          # the derived living_expense (and its source_record_id) could differ
          # run-to-run for identical data.
          containing = family.budgets
            .where("start_date <= ? AND end_date >= ?", as_of, as_of)
            .order(start_date: :desc, id: :asc)
            .first

          containing || family.budgets
            .where("start_date <= ?", as_of)
            .order(start_date: :desc, id: :asc)
            .first
        end
      end

      def primary_recurring_expense
        family.recurring_transactions
          .where(status: "active", destination_account_id: nil)
          .where("amount > 0")
          .order(amount: :desc)
          .first
      end

      # --- Persistence / provenance --------------------------------------------

      # Idempotently creates a source-derived assumption keyed by
      # (family, source_record_type, source_record_id). Reopening the plan finds
      # the existing row and makes no change. Always tagged with full provenance:
      # origin source_derived, review_state needs_review, source_refs, derived_at,
      # derivation_version (spec "Derivation Confidence").
      def upsert_derived_assumption(plan:, kind:, name:, amount:, currency:, confidence:, source_record:, params: {})
        return if existing_for_source(source_record)

        plan.forecast_assumptions.create!(
          family: family,
          kind: kind,
          name: name,
          status: :active,
          amount: amount,
          currency: currency,
          params: params,
          origin: :source_derived,
          confidence: confidence,
          review_state: :needs_review,
          source_record_type: source_record.class.name,
          source_record_id: source_record.id,
          source_refs: source_refs_for(source_record),
          derived_at: Time.current,
          derivation_version: DERIVATION_VERSION
        )
      end

      # Keyed by family + source record so the same source can never spawn two
      # derived assumptions (idempotency across reopen). Scoped to the family so
      # one family's snapshot never matches another's records.
      def existing_for_source(source_record)
        family.forecast_assumptions
          .where(source_record_type: source_record.class.name, source_record_id: source_record.id)
          .exists?
      end

      # Keyed by (family, plan, kind, derivation purpose): true when the plan
      # already carries a source-derived assumption of this kind from *any*
      # source. Lets a derivation that can switch sources between reopens (e.g.
      # budget -> recurring transaction) stay idempotent so it never double-counts.
      def existing_source_derived?(plan, kind)
        plan.forecast_assumptions
          .where(family: family, kind: kind, origin: :source_derived)
          .exists?
      end

      def source_refs_for(source_record)
        {
          "records" => [
            { "type" => source_record.class.name, "id" => source_record.id }
          ]
        }
      end

      # --- Helpers --------------------------------------------------------------

      def reporting_currency
        @reporting_currency ||= (family.currency.presence || "USD")
      end

      def to_decimal(value)
        return BigDecimal("0") if value.nil? || value == ""
        return value if value.is_a?(BigDecimal)

        BigDecimal(value.to_s)
      end
  end
end
