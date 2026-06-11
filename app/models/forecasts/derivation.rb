# frozen_string_literal: true

module Forecasts
  # Pure, READ-ONLY derivation of baseline assumption proposals from a family's
  # connected Sure data (recurring transactions, budgets, the income statement).
  # Extracted from DefaultPlanBuilder so the same precedence chain serves both
  # first-run seeding (DefaultPlanBuilder persists the proposals) and per-card
  # re-sync (Forecasts::Assumptions::ResyncsController previews/applies them)
  # without duplication. This class never writes; persistence, provenance
  # stamping, and idempotency stay with the callers.
  #
  # Two entry points, one per registered kind:
  #
  #   derivation = Forecasts::Derivation.new(family:, as_of:)
  #   derivation.salary_proposal(existing: nil)          # => Proposal or nil
  #   derivation.living_expense_proposal(existing: nil)  # => Proposal or nil
  #
  # Without `existing:` the full precedence chain runs (exactly the seeder's
  # rules). Callers pass `existing: nil` to RE-DERIVE an unlinked card from
  # scratch — e.g. a manual card the user wants to re-link to a real source —
  # so it re-runs the whole chain (budget → recurring → median, etc.) and can
  # land on a source record again. With `existing:` (an Assumption) the proposal
  # re-derives FROM THAT assumption's linked source: a linked record that no
  # longer exists or no longer qualifies yields a `status: :source_gone`
  # proposal; a source-record-less existing (median-fallback basis) re-runs the
  # same fallback basis. A nil return means "nothing to propose" (zero-skip).
  #
  # Family-scoping is anchored to the family passed in by the caller (always
  # Current.family at the call sites). Source records are re-resolved
  # family-scoped — a record belonging to another family reads as gone.
  class Derivation
    # Salary sources are recurring inflows landing on asset CASH accounts only.
    # An inflow on a liability account (CreditCard/Loan) is a bill payment TO
    # the liability, never income.
    SALARY_SOURCE_ACCOUNTABLE_TYPES = %w[Depository].freeze

    # Defaults for the editable params contract on derived proposals. The
    # drawer forms (SalaryForm/LivingExpenseForm) validate these fields on
    # every save, so a derived row must carry legal values the user can review:
    #   - person_key "primary": single-earner default; review confirms the earner.
    #   - gross_or_net "net": a recurring bank deposit is take-home pay.
    #   - frequency "monthly": recurring transactions and budgets are monthly.
    #   - growth/inflation policy "flat": no fabricated growth until confirmed.
    #   - actualization_policy "none": projection-only; never silently replaces
    #     or offsets actuals before the user reviews the assumption.
    DERIVED_PERSON_KEY = "primary"
    DERIVED_GROSS_OR_NET = "net"
    DERIVED_FREQUENCY = "monthly"
    DERIVED_GROWTH_POLICY = "flat"
    DERIVED_INFLATION_POLICY = "flat"
    DERIVED_ACTUALIZATION_POLICY = "none"

    # Kinds this class can derive a proposal for — the two registered entry
    # points below. Callers (e.g. the assumption card) gate the
    # "refresh from data" trigger on this rather than hardcoding the kind list,
    # so adding a `<kind>_proposal` entry point here lights up its trigger too.
    PROPOSAL_KINDS = %w[salary living_expense].freeze

    # True when `kind` has a derivation entry point (and so can be re-synced /
    # re-derived from connected data), regardless of an assumption's origin.
    def self.supports?(kind)
      PROPOSAL_KINDS.include?(kind.to_s)
    end

    attr_reader :family, :as_of

    def initialize(family:, as_of:)
      raise ArgumentError, "family is required" if family.nil?
      raise ArgumentError, "as_of is required" if as_of.nil?

      @family = family
      @as_of = as_of.to_date
    end

    # Salary precedence: largest active, non-transfer recurring inflow on an
    # asset CASH account -> income-statement median monthly income (low
    # confidence, source-record-less) -> nil when the median is zero.
    def salary_proposal(existing: nil)
      return resync_salary(existing) if existing

      deposit = primary_payroll_deposit
      return salary_proposal_from(deposit) if deposit

      median_income_proposal
    end

    # Living-expense precedence: current budget with positive budgeted_spending
    # -> largest active recurring outflow -> income-statement median monthly
    # expense (low confidence, source-record-less) -> nil when the median is zero.
    def living_expense_proposal(existing: nil)
      return resync_living_expense(existing) if existing

      budget = current_budget
      return budget_proposal(budget) if usable_budget?(budget)

      spend = primary_recurring_expense
      return recurring_expense_proposal(spend) if spend

      median_expense_proposal
    end

    private
      # --- Re-sync from an existing assumption --------------------------------

      def resync_salary(existing)
        return median_income_proposal if existing.source_record_type.blank?

        record = resolve_source_record(existing)
        return Proposal.source_gone(kind: "salary") unless usable_salary_source?(record)

        salary_proposal_from(record)
      end

      def resync_living_expense(existing)
        return median_expense_proposal if existing.source_record_type.blank?

        record = resolve_source_record(existing)
        case record
        when Budget
          usable_budget?(record) ? budget_proposal(record) : Proposal.source_gone(kind: "living_expense")
        when RecurringTransaction
          usable_expense_source?(record) ? recurring_expense_proposal(record) : Proposal.source_gone(kind: "living_expense")
        else
          Proposal.source_gone(kind: "living_expense")
        end
      end

      # Resolves the assumption's linked source record, FAMILY-SCOPED: a record
      # that no longer exists, can't be constantized, or belongs to another
      # family resolves to nil (and reads as source_gone upstream).
      def resolve_source_record(assumption)
        klass = assumption.source_record_type.safe_constantize
        return nil unless klass.respond_to?(:find_by)

        record = klass.find_by(id: assumption.source_record_id)
        return nil if record.nil?
        return nil if record.respond_to?(:family_id) && record.family_id != family.id

        record
      end

      # The same qualification gates the precedence-chain query enforces, so a
      # re-derive can never propose from a source the seeder would now reject.
      def usable_salary_source?(record)
        record.is_a?(RecurringTransaction) &&
          record.status == "active" &&
          record.destination_account_id.nil? &&
          to_decimal(record.amount).negative? &&
          SALARY_SOURCE_ACCOUNTABLE_TYPES.include?(record.account&.accountable_type)
      end

      def usable_budget?(budget)
        budget.present? && to_decimal(budget.budgeted_spending).positive?
      end

      def usable_expense_source?(record)
        record.is_a?(RecurringTransaction) &&
          record.status == "active" &&
          record.destination_account_id.nil? &&
          to_decimal(record.amount).positive?
      end

      # --- Salary chain (moved from DefaultPlanBuilder) ------------------------

      # `joins(:account)` + the Depository filter restricts candidates to
      # recurring inflows landing on asset cash accounts (and drops rows with
      # no account, which cannot be proven to be income). Transfers are already
      # excluded via `destination_account_id: nil`.
      def primary_payroll_deposit
        @primary_payroll_deposit ||= family.recurring_transactions
          .joins(:account)
          .where(status: "active", destination_account_id: nil)
          .where(accounts: { accountable_type: SALARY_SOURCE_ACCOUNTABLE_TYPES })
          .where("recurring_transactions.amount < 0")
          .to_a
          .max_by { |recurring| income_magnitude(recurring) }
      end

      def salary_proposal_from(deposit)
        amount = income_magnitude(deposit)
        Proposal.new(
          kind: "salary",
          name: salary_name(deposit),
          amount: amount,
          currency: deposit.currency,
          confidence: "medium",
          source_record: deposit,
          source_refs: source_refs_for(deposit),
          needs_review: true,
          params: salary_params(amount: amount, currency: deposit.currency, cash_account_id: deposit.account_id)
        )
      end

      # Median-income fallback: a low-confidence, source-record-less salary
      # estimate from the income statement. Nil when the family has no
      # measurable income (zero-skip).
      def median_income_proposal
        median = to_decimal(family.income_statement.median_income)
        return nil unless median.positive?

        Proposal.new(
          kind: "salary",
          name: "Estimated income",
          amount: median,
          currency: reporting_currency,
          confidence: "low",
          source_record: nil,
          source_refs: { "records" => [], "basis" => "income_statement_median_income" },
          needs_review: true,
          params: salary_params(amount: median, currency: reporting_currency, cash_account_id: nil)
        )
      end

      def salary_name(deposit)
        deposit.name.presence || deposit.merchant&.name.presence || "Salary"
      end

      # Income is stored as a negative recurring amount; expose it as a positive
      # salary figure.
      def income_magnitude(recurring)
        to_decimal(recurring.amount).abs
      end

      # --- Living-expense chain (moved from DefaultPlanBuilder) ----------------

      # Current budget: the budget whose period contains as_of, falling back to
      # the latest budget that has started on or before as_of. `id ASC` is a
      # deterministic final tiebreaker.
      def current_budget
        @current_budget ||= begin
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

      def budget_proposal(budget)
        amount = to_decimal(budget.budgeted_spending)
        Proposal.new(
          kind: "living_expense",
          name: "Living expenses",
          amount: amount,
          currency: budget.currency,
          confidence: "medium",
          source_record: budget,
          source_refs: source_refs_for(budget),
          needs_review: true,
          params: living_expense_params(amount: amount, currency: budget.currency, basis: "budget")
        )
      end

      def recurring_expense_proposal(spend)
        amount = to_decimal(spend.amount).abs
        Proposal.new(
          kind: "living_expense",
          name: spend.name.presence || "Living expenses",
          amount: amount,
          currency: spend.currency,
          confidence: "medium",
          source_record: spend,
          source_refs: source_refs_for(spend),
          needs_review: true,
          params: living_expense_params(amount: amount, currency: spend.currency, basis: "recurring_average")
        )
      end

      # Median-expense fallback: a low-confidence, source-record-less living
      # expense estimate. Nil when the family has no measurable spending.
      def median_expense_proposal
        median = to_decimal(family.income_statement.median_expense)
        return nil unless median.positive?

        Proposal.new(
          kind: "living_expense",
          name: "Estimated living expenses",
          amount: median,
          currency: reporting_currency,
          confidence: "low",
          source_record: nil,
          source_refs: { "records" => [], "basis" => "income_statement_median_expense" },
          needs_review: true,
          params: living_expense_params(amount: median, currency: reporting_currency, basis: "median_expense")
        )
      end

      # --- Params contracts / shared helpers (moved from DefaultPlanBuilder) ---

      def salary_params(amount:, currency:, cash_account_id:)
        Forecasts::Assumptions::SalaryParams.new(
          person_key: DERIVED_PERSON_KEY,
          amount: amount,
          gross_or_net: DERIVED_GROSS_OR_NET,
          currency: currency,
          frequency: DERIVED_FREQUENCY,
          growth_policy: DERIVED_GROWTH_POLICY,
          cash_account_id: cash_account_id,
          start_anchor: nil,
          end_anchor: nil
        ).to_h
      end

      # `basis` records which derivation source produced the figure (budget vs
      # recurring_average vs median_expense) on top of the standard contract keys.
      def living_expense_params(amount:, currency:, basis:)
        Forecasts::Assumptions::LivingExpenseParams.new(
          amount: amount,
          currency: currency,
          frequency: DERIVED_FREQUENCY,
          category_ids: [],
          inflation_policy: DERIVED_INFLATION_POLICY,
          actualization_policy: DERIVED_ACTUALIZATION_POLICY,
          start_anchor: nil,
          end_anchor: nil
        ).to_h.merge("basis" => basis)
      end

      def source_refs_for(source_record)
        {
          "records" => [
            { "type" => source_record.class.name, "id" => source_record.id }
          ]
        }
      end

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
