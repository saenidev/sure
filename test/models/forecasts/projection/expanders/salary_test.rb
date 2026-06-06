# frozen_string_literal: true

require "test_helper"

# Unit tests for the pure salary assumption expander. The expander receives
# typed params, the normalized source-snapshot context, scenario context, and
# resolved milestone dates (NO ActiveRecord). It produces dated income flows
# with gross/net interpretation and trace links. See spec "Assumption
# Expansion", "Flow Ledger", and the salary row of "Assumption Params
# Contracts".
class Forecasts::Projection::Expanders::SalaryTest < ActiveSupport::TestCase
  def context(overrides = {})
    {
      assumption_id: "aaaa1111-1111-1111-1111-111111111111",
      scenario_layer_id: nil,
      plan_version: 7,
      reporting_currency: "USD",
      horizon: { starts_on: "2026-01-01", ends_on: "2031-01-01" },
      milestone_dates: {},
      run_date: "2026-01-01"
    }.merge(overrides)
  end

  def salary_params(overrides = {})
    {
      person_key: "primary",
      amount: "6000.00",
      gross_or_net: "net",
      currency: "USD",
      frequency: "monthly",
      growth_policy: { type: "none" },
      start_anchor: { type: "date", on: "2026-01-01" },
      end_anchor: { type: "date", on: "2026-12-01" }
    }.merge(overrides)
  end

  def expand(params: salary_params, ctx: context)
    Forecasts::Projection::Expanders::Salary.new(params: params, context: ctx).expand
  end

  # --- Frequency expansion -------------------------------------------------

  test "monthly salary expands into one income flow per month within the window" do
    flows = expand

    assert_equal 12, flows.length
    assert_equal %w[2026-01-01 2026-02-01], flows.first(2).map(&:date).map(&:iso8601)
    assert_equal Date.new(2026, 12, 1), flows.last.date
  end

  test "every flow is income inflow tagged to the salary assumption" do
    flow = expand.first

    assert_equal "income", flow.category
    assert_equal "inflow", flow.direction
    assert_equal "aaaa1111-1111-1111-1111-111111111111", flow.assumption_id
    assert_equal "salary", flow.source_kind
  end

  test "annual frequency expands into one flow per year on the anchor day" do
    flows = expand(
      params: salary_params(
        frequency: "annual",
        start_anchor: { type: "date", on: "2026-03-15" },
        end_anchor: { type: "date", on: "2029-03-15" }
      )
    )

    assert_equal 4, flows.length
    assert_equal(
      %w[2026-03-15 2027-03-15 2028-03-15 2029-03-15],
      flows.map(&:date).map(&:iso8601)
    )
  end

  test "biweekly frequency expands every 14 days" do
    flows = expand(
      params: salary_params(
        frequency: "biweekly",
        start_anchor: { type: "date", on: "2026-01-01" },
        end_anchor: { type: "date", on: "2026-02-28" }
      )
    )

    assert_equal(
      %w[2026-01-01 2026-01-15 2026-01-29 2026-02-12 2026-02-26],
      flows.map(&:date).map(&:iso8601)
    )
  end

  test "one_time frequency produces a single flow on the start anchor" do
    flows = expand(
      params: salary_params(
        frequency: "one_time",
        start_anchor: { type: "date", on: "2026-05-10" },
        end_anchor: { type: "date", on: "2028-01-01" }
      )
    )

    assert_equal 1, flows.length
    assert_equal Date.new(2026, 5, 10), flows.first.date
  end

  # --- Gross / net interpretation ------------------------------------------

  test "net salary carries identical gross and net amounts" do
    flow = expand.first

    assert_equal "6000.00", flow.net_amount
    assert_equal "6000.00", flow.gross_amount
    assert_equal "6000.00", flow.amount
    assert_equal "net", flow.gross_or_net
  end

  test "gross salary derives net using the net ratio and keeps both amounts traceable" do
    flow = expand(
      params: salary_params(gross_or_net: "gross", amount: "10000.00", net_ratio: "0.70")
    ).first

    assert_equal "gross", flow.gross_or_net
    assert_equal "10000.00", flow.gross_amount
    assert_equal "7000.00", flow.net_amount
    # Cash impact uses the net (take-home) amount.
    assert_equal "7000.00", flow.amount
  end

  test "gross salary without a net ratio falls back to gross as net" do
    flow = expand(params: salary_params(gross_or_net: "gross", amount: "10000.00")).first

    assert_equal "10000.00", flow.gross_amount
    assert_equal "10000.00", flow.net_amount
  end

  # --- Growth --------------------------------------------------------------

  test "annual percentage growth compounds on each anniversary of the start" do
    flows = expand(
      params: salary_params(
        amount: "1000.00",
        growth_policy: { type: "annual_percentage", rate: "0.10" },
        start_anchor: { type: "date", on: "2026-01-01" },
        end_anchor: { type: "date", on: "2028-01-01" }
      )
    )

    by_year = flows.group_by { |f| f.date.year }
    assert_equal "1000.00", by_year[2026].first.amount
    assert_equal "1100.00", by_year[2027].first.amount
    assert_equal "1210.00", by_year[2028].first.amount
  end

  # --- Milestone end-anchor ------------------------------------------------

  test "end anchor resolves a milestone reference to its deterministic date" do
    flows = expand(
      params: salary_params(
        frequency: "annual",
        start_anchor: { type: "date", on: "2026-01-01" },
        end_anchor: { type: "milestone", milestone_key: "retirement" }
      ),
      ctx: context(milestone_dates: { "retirement" => "2028-01-01" })
    )

    assert_equal Date.new(2028, 1, 1), flows.last.date
    assert_equal 3, flows.length
  end

  test "start anchor before the horizon clamps forward to the horizon start" do
    flows = expand(
      params: salary_params(
        start_anchor: { type: "date", on: "2020-01-01" },
        end_anchor: { type: "date", on: "2026-03-01" }
      ),
      ctx: context(horizon: { starts_on: "2026-01-01", ends_on: "2031-01-01" })
    )

    assert_equal Date.new(2026, 1, 1), flows.first.date
  end

  test "end anchor past the horizon clamps to the horizon end" do
    flows = expand(
      params: salary_params(
        start_anchor: { type: "date", on: "2026-01-01" },
        end_anchor: { type: "date", on: "2099-01-01" }
      ),
      ctx: context(horizon: { starts_on: "2026-01-01", ends_on: "2026-04-01" })
    )

    assert_equal Date.new(2026, 4, 1), flows.last.date
    assert_equal 4, flows.length
  end

  # --- Trace metadata ------------------------------------------------------

  test "flows carry scenario layer id and a stable flow key" do
    ctx = context(scenario_layer_id: "layer-9")
    flow = expand(ctx: ctx).first

    assert_equal "layer-9", flow.scenario_layer_id
    assert_equal "salary", flow.source_kind
    refute_nil flow.flow_key
    # Same inputs produce the same stable flow key.
    assert_equal flow.flow_key, expand(ctx: ctx).first.flow_key
  end

  test "flows convert into trace-ready hashes with money as decimal strings" do
    hash = expand.first.to_h

    assert_kind_of String, hash[:amount]
    assert_equal "income", hash[:category]
    assert_equal "inflow", hash[:direction]
    assert_equal "USD", hash[:currency]
  end

  # --- Determinism & disabled ---------------------------------------------

  test "expansion is deterministic for the same params and context" do
    a = expand.map(&:to_h)
    b = expand.map(&:to_h)

    assert_equal a, b
  end

  test "an end anchor before the start anchor produces no flows" do
    flows = expand(
      params: salary_params(
        start_anchor: { type: "date", on: "2026-06-01" },
        end_anchor: { type: "date", on: "2026-01-01" }
      )
    )

    assert_empty flows
  end
end
