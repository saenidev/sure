# frozen_string_literal: true

module Forecasts
  # Deterministic scenario builder for the Forecast V2 end-to-end PROOF SLICE
  # system test (slice C9, spec "Mandatory End-To-End Proof Slice").
  #
  # The proof-slice exit gate opens the REAL `/forecast` route (V2 flag on) for a
  # connected family and walks the populated -> selected-period -> salary editor ->
  # saving -> issue-limited states. Each of those states needs known source data so
  # the default plan derives predictable salary + living-expense assumptions and the
  # engine produces a stable projection. This builder shapes the `dylan_family`
  # fixture into that one connected family:
  #
  #   - #build:           a recurring USD payroll inflow (the salary source) + a
  #                       current USD budget (the living-expense source) -> the
  #                       populated default-plan state every screenshot but the
  #                       issue-limited one is captured from.
  #   - #seed_missing_fx: the same shape but the payroll inflow is in a foreign
  #                       currency (EUR) with NO EUR->reporting FX rate as_of, so the
  #                       derived salary becomes a foreign-currency FLOW the engine
  #                       cannot convert. The period simulator records a structured
  #                       `missing_fx_rate` issue (NOT an exception, NOT a raw UUID),
  #                       which the projection cache stores and the IssuePanel renders
  #                       inside the plan shell -> the issue-limited screenshot.
  #
  # This is NOT an ActiveRecord fixture YAML file: the proof slice asserts
  # source-derived assumptions, so the source records must exist with KNOWN values
  # threaded by an explicit `as_of` (YAML fixtures cannot express the as_of thread
  # cleanly). It lives under test/fixtures/files/forecasts so the system test can
  # `require` it. It mirrors the backend-proof `connected_family_proof.rb` builder
  # but is the dedicated, UI-facing seed the screenshot baseline matrix reads from.
  #
  # Everything is threaded by an explicit `as_of` so the proof slice never relies on
  # Date.current leaking into the snapshot/packet/engine path. The system test passes
  # `Date.current` so the seed lines up with the controller's request-boundary clock.
  module ProofSliceSeed
    module_function

    SALARY_AMOUNT = -6_000           # negative == inflow under Sure's sign rule
    BUDGET_SPENDING = 4_000
    DERIVED_SALARY_AMOUNT = BigDecimal("6000")
    DERIVED_LIVING_AMOUNT = BigDecimal("4000")

    # The populated default-plan scenario: a USD payroll inflow + a current USD
    # budget. Returns a small result struct the test can read (the family, the
    # as_of, and the two source records the default plan derives assumptions from).
    def build(family:, account:, budget:, as_of:)
      as_of = as_of.to_date

      payroll = build_payroll(family: family, account: account, as_of: as_of, currency: "USD")
      configured_budget = configure_budget(budget: budget, as_of: as_of)

      Scenario.new(
        family: family,
        as_of: as_of,
        payroll: payroll,
        budget: configured_budget
      )
    end

    # The issue-limited scenario: the same connected shape, but the payroll inflow
    # is in EUR with NO EUR->reporting FX rate available as_of. The default plan
    # derives a EUR salary; the engine cannot convert that flow and records a
    # structured `missing_fx_rate` issue (severity "error", privacy-safe code), so
    # the projection cache's issue summary carries `missing_fx_rate` and the
    # IssuePanel renders it inside the plan shell. Returns the same Scenario struct.
    def seed_missing_fx(family:, account:, budget:, as_of:)
      as_of = as_of.to_date

      # No EUR -> reporting-currency rate exists, so the converted value cannot be
      # produced and the engine emits the structured issue instead of raising.
      payroll = build_payroll(family: family, account: account, as_of: as_of, currency: "EUR")
      configured_budget = configure_budget(budget: budget, as_of: as_of)

      Scenario.new(
        family: family,
        as_of: as_of,
        payroll: payroll,
        budget: configured_budget
      )
    end

    # A recurring, active, non-transfer payroll inflow. Largest-magnitude inflow so
    # the default plan picks it as the primary salary source. The currency drives
    # whether the derived salary flow needs FX conversion (populated vs issue-limited).
    def build_payroll(family:, account:, as_of:, currency:)
      family.recurring_transactions.create!(
        account: account,
        name: "Acme Payroll",
        amount: SALARY_AMOUNT,
        currency: currency,
        expected_day_of_month: 1,
        last_occurrence_date: as_of - 1.month,
        next_expected_date: as_of + 1.month,
        status: "active",
        occurrence_count: 6
      )
    end

    # Anchors the fixture budget around `as_of` with a known spending figure so it
    # is the "current budget" the living-expense assumption prefers and derives.
    def configure_budget(budget:, as_of:)
      budget.update!(
        start_date: as_of.beginning_of_month,
        end_date: as_of.end_of_month,
        budgeted_spending: BUDGET_SPENDING
      )
      budget
    end

    Scenario = Struct.new(:family, :as_of, :payroll, :budget, keyword_init: true)
  end
end
