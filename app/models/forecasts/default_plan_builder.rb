# frozen_string_literal: true

module Forecasts
  # Forecast V2 default plan builder. When a family opens `/forecast` and has no
  # active V2 plan, this application service creates exactly one active
  # `Forecasts::Plan` and persists the baseline assumption proposals produced by
  # Forecasts::Derivation (the read-only precedence-chain component):
  #
  #   - a `salary` assumption from a recurring payroll deposit (or the
  #     income-statement median income), and
  #   - a `living_expense` assumption from the current budget, a recurring
  #     outflow, or the income-statement median monthly expense.
  #
  # This class owns plan creation + persistence/provenance/idempotency ONLY;
  # the derivation rules themselves live in Forecasts::Derivation so the same
  # chain serves the per-card re-sync endpoints. See spec "Default Plan
  # Derivation", "Bootstrap Rules", "Source-To-Assumption Mapping",
  # "Derivation Confidence".
  #
  # The build is idempotent (spec "Bootstrap Rules"): reopening `/forecast` must
  # not duplicate plans or assumptions. Plans are keyed by "the family has no
  # active V2 plan". Derived assumptions are keyed both by `(family, source
  # record)` and by derivation purpose `(family, plan, kind, source_derived)` —
  # the latter because a derivation source can switch between reopens (e.g.
  # budget -> recurring transaction) and must not double-count.
  #
  # Family-scoping is anchored to the family passed in by the caller (which is
  # always `Current.family` at the call site). The builder never reads another
  # family's data and never trusts a family_id from arbitrary params.
  class DefaultPlanBuilder
    DERIVATION_VERSION = "forecast-derivation-v1"
    # default 3y; the engine and perf budgets are sized for the 360-month
    # maximum (user-configurable horizon UI arrives in a later phase)
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

      # Derives the baseline assumptions, each guarded by its derivation-purpose
      # key so reopening the plan is a no-op. Returns the plan for chaining.
      def ensure_baseline_assumptions(plan)
        derive_salary(plan)
        derive_living_expense(plan)
        plan
      end

      def derive_salary(plan)
        return if existing_source_derived?(plan, "salary")

        persist_proposal(plan, derivation.salary_proposal)
      end

      def derive_living_expense(plan)
        return if existing_source_derived?(plan, "living_expense")

        persist_proposal(plan, derivation.living_expense_proposal)
      end

      def derivation
        @derivation ||= Forecasts::Derivation.new(family: family, as_of: as_of)
      end

      # nil proposal == nothing to derive (zero-skip); the plan simply starts
      # without that assumption.
      def persist_proposal(plan, proposal)
        return if proposal.nil?

        upsert_derived_assumption(
          plan: plan,
          kind: proposal.kind,
          name: proposal.name,
          amount: proposal.amount,
          currency: proposal.currency,
          confidence: proposal.confidence,
          source_record: proposal.source_record,
          source_refs: proposal.source_refs,
          params: proposal.params
        )
      end

      # --- Persistence / provenance --------------------------------------------

      # Idempotently creates a source-derived assumption keyed by
      # (family, source_record_type, source_record_id). Reopening the plan finds
      # the existing row and makes no change. Always tagged with full provenance:
      # origin source_derived, review_state needs_review, source_refs, derived_at,
      # derivation_version (spec "Derivation Confidence"). `source_record` may be
      # nil for derivations with no single source row (the median fallbacks);
      # those proposals carry explicit `source_refs` and rely on the kind-level
      # `existing_source_derived?` guard for idempotency.
      def upsert_derived_assumption(plan:, kind:, name:, amount:, currency:, confidence:, source_record:, source_refs:, params:)
        return if source_record && existing_for_source(source_record)

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
          source_record_type: source_record&.class&.name,
          source_record_id: source_record&.id,
          source_refs: source_refs,
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

      def reporting_currency
        @reporting_currency ||= (family.currency.presence || "USD")
      end
  end
end
