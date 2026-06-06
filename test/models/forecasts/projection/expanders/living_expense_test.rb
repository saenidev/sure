# frozen_string_literal: true

require "test_helper"

# Unit tests for the pure living-expense assumption expander. The expander
# receives typed params, normalized source-snapshot context, scenario context,
# and resolved milestone dates (NO ActiveRecord). It produces dated spending
# flows with inflation, a category rollup, and trace links. See spec
# "Assumption Expansion", "Flow Ledger", and the living_expense row of
# "Assumption Params Contracts".
class Forecasts::Projection::Expanders::LivingExpenseTest < ActiveSupport::TestCase
  def context(overrides = {})
    {
      assumption_id: "bbbb2222-2222-2222-2222-222222222222",
      scenario_layer_id: nil,
      plan_version: 3,
      reporting_currency: "USD",
      horizon: { starts_on: "2026-01-01", ends_on: "2031-01-01" },
      milestone_dates: {},
      run_date: "2026-01-01"
    }.merge(overrides)
  end

  def living_expense_params(overrides = {})
    {
      amount: "2800.00",
      currency: "USD",
      frequency: "monthly",
      category_ids: %w[cat-housing cat-utilities],
      inflation_policy: { type: "none" },
      actualization_policy: { type: "expected_only" },
      start_anchor: { type: "date", on: "2026-01-01" },
      end_anchor: { type: "date", on: "2026-06-01" }
    }.merge(overrides)
  end

  def expand(params: living_expense_params, ctx: context)
    Forecasts::Projection::Expanders::LivingExpense.new(params: params, context: ctx).expand
  end

  # --- Frequency expansion -------------------------------------------------

  test "monthly living expense expands into one spending flow per month" do
    flows = expand

    assert_equal 6, flows.length
    assert_equal Date.new(2026, 1, 1), flows.first.date
    assert_equal Date.new(2026, 6, 1), flows.last.date
  end

  test "every flow is a spending outflow tagged to the assumption" do
    flow = expand.first

    assert_equal "spending", flow.category
    assert_equal "outflow", flow.direction
    assert_equal "bbbb2222-2222-2222-2222-222222222222", flow.assumption_id
    assert_equal "living_expense", flow.source_kind
  end

  test "quarterly frequency expands every three months" do
    flows = expand(
      params: living_expense_params(
        frequency: "quarterly",
        start_anchor: { type: "date", on: "2026-01-01" },
        end_anchor: { type: "date", on: "2026-12-31" }
      )
    )

    assert_equal(
      %w[2026-01-01 2026-04-01 2026-07-01 2026-10-01],
      flows.map(&:date).map(&:iso8601)
    )
  end

  # --- Inflation -----------------------------------------------------------

  test "annual inflation compounds on each anniversary of the start" do
    flows = expand(
      params: living_expense_params(
        amount: "1000.00",
        inflation_policy: { type: "annual_percentage", rate: "0.05" },
        start_anchor: { type: "date", on: "2026-01-01" },
        end_anchor: { type: "date", on: "2028-01-01" }
      )
    )

    by_year = flows.group_by { |f| f.date.year }
    assert_equal "1000.00", by_year[2026].first.amount
    assert_equal "1050.00", by_year[2027].first.amount
    assert_equal "1102.50", by_year[2028].first.amount
  end

  test "no inflation policy keeps the amount flat across the window" do
    flows = expand(
      params: living_expense_params(
        amount: "2800.00",
        inflation_policy: { type: "none" },
        start_anchor: { type: "date", on: "2026-01-01" },
        end_anchor: { type: "date", on: "2028-01-01" }
      )
    )

    assert_equal [ "2800.00" ], flows.map(&:amount).uniq
  end

  # --- Category rollup -----------------------------------------------------

  test "flows carry the category rollup from params" do
    flow = expand.first

    assert_equal %w[cat-housing cat-utilities], flow.category_ids
  end

  test "category rollup is empty when no categories are configured" do
    flow = expand(params: living_expense_params(category_ids: nil)).first

    assert_equal [], flow.category_ids
  end

  # --- Milestone end-anchor ------------------------------------------------

  test "end anchor resolves a milestone reference to its deterministic date" do
    flows = expand(
      params: living_expense_params(
        frequency: "annual",
        start_anchor: { type: "date", on: "2026-01-01" },
        end_anchor: { type: "milestone", milestone_key: "move" }
      ),
      ctx: context(milestone_dates: { "move" => "2028-01-01" })
    )

    assert_equal Date.new(2028, 1, 1), flows.last.date
    assert_equal 3, flows.length
  end

  # --- Trace metadata ------------------------------------------------------

  test "flows carry scenario layer id and a stable, deterministic flow key" do
    ctx = context(scenario_layer_id: "layer-move")
    flow = expand(ctx: ctx).first

    assert_equal "layer-move", flow.scenario_layer_id
    assert_equal flow.flow_key, expand(ctx: ctx).first.flow_key
  end

  test "flows convert into trace-ready hashes with money as decimal strings" do
    hash = expand.first.to_h

    assert_kind_of String, hash[:amount]
    assert_equal "spending", hash[:category]
    assert_equal "outflow", hash[:direction]
    assert_equal "USD", hash[:currency]
    assert_equal %w[cat-housing cat-utilities], hash[:category_ids]
  end

  # --- Determinism ---------------------------------------------------------

  test "expansion is deterministic for the same params and context" do
    assert_equal expand.map(&:to_h), expand.map(&:to_h)
  end
end
