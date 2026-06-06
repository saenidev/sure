# frozen_string_literal: true

require "test_helper"

# Unit tests for the pure flow ledger: the normalized, deterministically ordered
# list of dated effects produced by assumption expansion. See spec "Flow
# Ledger" and "Flow Ordering".
class Forecasts::Projection::FlowLedgerTest < ActiveSupport::TestCase
  Flow = Forecasts::Projection::FlowLedger::Flow

  def flow(date:, category:, direction:, amount: "100.00", sequence: 0, key: nil)
    Flow.new(
      date: date,
      amount: amount,
      currency: "USD",
      category: category,
      direction: direction,
      source_kind: category == "income" ? "salary" : "living_expense",
      assumption_id: "a-1",
      scenario_layer_id: nil,
      flow_key: key || "#{category}-#{date}-#{sequence}",
      sequence: sequence
    )
  end

  test "orders by date, then income before spending within a period" do
    spending = flow(date: Date.new(2026, 1, 1), category: "spending", direction: "outflow")
    income = flow(date: Date.new(2026, 1, 1), category: "income", direction: "inflow")
    later = flow(date: Date.new(2026, 2, 1), category: "income", direction: "inflow")

    ledger = Forecasts::Projection::FlowLedger.new([ later, spending, income ])

    assert_equal [ income, spending, later ], ledger.flows
  end

  test "is immutable and frozen" do
    ledger = Forecasts::Projection::FlowLedger.new([])

    assert ledger.frozen?
    assert ledger.flows.frozen?
  end

  test "merge returns a new ordered ledger preserving the global order" do
    a = flow(date: Date.new(2026, 3, 1), category: "income", direction: "inflow")
    b = flow(date: Date.new(2026, 1, 1), category: "spending", direction: "outflow")

    merged = Forecasts::Projection::FlowLedger.new([ a ]).merge([ b ])

    assert_equal [ b, a ], merged.flows
    assert_equal 2, merged.size
  end

  test "for_period filters flows whose date falls within the period" do
    jan = flow(date: Date.new(2026, 1, 31), category: "income", direction: "inflow", key: "jan")
    feb = flow(date: Date.new(2026, 2, 1), category: "income", direction: "inflow", key: "feb")

    ledger = Forecasts::Projection::FlowLedger.new([ feb, jan ])

    assert_equal [ jan ], ledger.for_period("2026-01")
    assert_equal [ feb ], ledger.for_period("2026-02")
  end

  test "Flow rejects float amounts to keep money as decimal strings" do
    assert_raises(Forecasts::Projection::FlowLedger::Flow::InvalidFlowError) do
      Flow.new(
        date: Date.new(2026, 1, 1),
        amount: 100.0,
        currency: "USD",
        category: "income",
        direction: "inflow",
        source_kind: "salary",
        assumption_id: "a-1",
        flow_key: "k"
      )
    end
  end

  test "Flow rejects unknown categories" do
    assert_raises(Forecasts::Projection::FlowLedger::Flow::InvalidFlowError) do
      Flow.new(
        date: Date.new(2026, 1, 1),
        amount: "1.00",
        currency: "USD",
        category: "teleport",
        direction: "inflow",
        source_kind: "salary",
        assumption_id: "a-1",
        flow_key: "k"
      )
    end
  end

  test "period_key reflects the calendar month containing the flow date" do
    assert_equal "2026-12", flow(date: Date.new(2026, 12, 5), category: "income", direction: "inflow").period_key
  end
end
