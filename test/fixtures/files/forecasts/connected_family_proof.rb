# frozen_string_literal: true

module Forecasts
  # Test-only scenario builder for the Forecast V2 backend proof slice
  # (spec "Backend Proof Slice"). It shapes the `dylan_family` fixture into the
  # one connected family the proof slice opens the default plan for: a recurring
  # payroll deposit (salary source) and a current budget (living-expense source),
  # plus connected accounts/balances that already exist in fixtures.
  #
  # This is NOT an ActiveRecord fixture YAML file. It is a deterministic, inline
  # scenario builder (the proof slice asserts source-derived assumptions, so the
  # source records must exist with known values, which YAML fixtures alone do not
  # express cleanly alongside the `as_of` thread). It lives under
  # test/fixtures/files/forecasts so the proof-slice test can require it.
  #
  # Everything is threaded by an explicit `as_of` so the proof slice never relies
  # on Date.current leaking into the snapshot/packet/engine path.
  module ConnectedFamilyProof
    module_function

    SALARY_AMOUNT = -6_000           # negative == inflow under Sure's sign rule
    BUDGET_SPENDING = 4_000
    DERIVED_SALARY_AMOUNT = BigDecimal("6000")
    DERIVED_LIVING_AMOUNT = BigDecimal("4000")

    # Builds the connected-family scenario and returns a small result struct the
    # proof-slice test reads (the family, the as_of, and the two source records
    # the default plan is expected to derive assumptions from).
    #
    # Pass the fixture accessors from the test (the proof test is an
    # ActiveSupport::TestCase, so `families`/`accounts`/`budgets` are available
    # there but not here).
    def build(family:, depository_account:, budget:, as_of:)
      as_of = as_of.to_date

      payroll = build_payroll(family: family, account: depository_account, as_of: as_of)
      configured_budget = configure_budget(budget: budget, as_of: as_of)

      Scenario.new(
        family: family,
        as_of: as_of,
        payroll: payroll,
        budget: configured_budget
      )
    end

    # Adds a foreign-currency account with NO usable FX rate as_of, so the source
    # snapshot records a structured `missing_fx_rate` issue candidate and the
    # engine returns a structured issue instead of raising. Returns the account.
    def add_unconvertible_foreign_account(family:)
      family.accounts.create!(
        name: "Yen Cash (no rate)",
        balance: 500_000,
        currency: "JPY",
        accountable: Depository.new
      )
    end

    # A recurring, active, non-transfer payroll inflow. Largest-magnitude inflow
    # so the default plan picks it as the primary salary source.
    def build_payroll(family:, account:, as_of:)
      family.recurring_transactions.create!(
        account: account,
        name: "Acme Payroll",
        amount: SALARY_AMOUNT,
        currency: "USD",
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
