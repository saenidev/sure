# frozen_string_literal: true

require "test_helper"
require "ostruct"

# Drift scanner (phase 5). Critical behaviors per the spec drift model:
# re-derive each LINKED source-derived assumption, write a drift verdict when
# the proposal moved >= 15% (or recovered from a $0 seed), clear it when back
# under threshold, honor soft dismiss + permanent silence, never touch
# lock_version/updated_at, and record the key the scan ran under.
class Forecasts::Drift::ScannerTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @as_of = Date.new(2026, 6, 1)
    @plan = Forecasts::Plan.create!(
      family: @family,
      name: "Drift plan",
      horizon_start_on: @as_of,
      horizon_end_on: @as_of >> 36,
      reporting_currency: "USD"
    )
    # Task 1's Derivation is a collaborator — stub the boundary, test only
    # that the scanner calls it correctly and interprets the Proposal VO.
    @derivation = mock("derivation")
    Forecasts::Derivation.stubs(:new).returns(@derivation)
  end

  test "writes drift when the proposal moved beyond the threshold" do
    assumption = linked_assumption(amount: 1100)
    @derivation.stubs(:salary_proposal).returns(proposal(amount: "1340"))

    scan!

    drift = assumption.reload.drift
    assert_equal "drifted", drift["status"]
    assert_equal "1340.0", drift["proposed_amount"]
    assert_equal "1100.0", drift["current_amount"]
    assert_in_delta 0.2182, BigDecimal(drift["relative"]).to_f, 0.0001
    assert drift["computed_at"].present?
  end

  test "clears stale drift when the proposal is back under the threshold" do
    assumption = linked_assumption(amount: 1100)
    assumption.update_columns(drift: { "status" => "drifted" })
    @derivation.stubs(:salary_proposal).returns(proposal(amount: "1150"))

    scan!

    assert_nil assumption.reload.drift
  end

  test "zero current amount with a positive proposal always drifts, with nil relative" do
    assumption = linked_assumption(amount: 0)
    @derivation.stubs(:salary_proposal).returns(proposal(amount: "500"))

    scan!

    drift = assumption.reload.drift
    assert_equal "drifted", drift["status"]
    assert_equal "500.0", drift["proposed_amount"]
    assert_equal "0.0", drift["current_amount"]
    assert_nil drift["relative"]
  end

  test "soft dismiss suppresses the nudge until the proposal moves" do
    assumption = linked_assumption(amount: 1100, drift_dismissed_amount: 1340)
    @derivation.stubs(:salary_proposal).returns(proposal(amount: "1340"))

    scan!
    assert_nil assumption.reload.drift, "dismissed amount unchanged -> suppressed"

    @derivation.stubs(:salary_proposal).returns(proposal(amount: "1400"))
    scan!
    assert_equal "drifted", assumption.reload.drift["status"],
      "a moved proposal re-arms the nudge"
  end

  test "permanently silenced assumptions are never re-derived" do
    assumption = linked_assumption(amount: 1100, drift_silenced_at: Time.current)
    @derivation.expects(:salary_proposal).never

    scan!

    assert_nil assumption.reload.drift
  end

  test "source-less (median fallback) assumptions are never re-derived" do
    assumption = linked_assumption(
      amount: 1100, source_record_type: nil, source_record_id: nil
    )
    @derivation.expects(:salary_proposal).never

    scan!

    assert_nil assumption.reload.drift
  end

  test "a nil re-derive (median fallback at zero) is skipped without raising" do
    assumption = linked_assumption(amount: 1100)
    @derivation.stubs(:salary_proposal).returns(nil)

    assert_nothing_raised { scan! }

    assert_nil assumption.reload.drift
  end

  test "a gone source writes a source_gone verdict" do
    assumption = linked_assumption(amount: 1100)
    @derivation.stubs(:salary_proposal)
      .returns(proposal(amount: nil, status: :source_gone))

    scan!

    drift = assumption.reload.drift
    assert_equal "source_gone", drift["status"]
    assert_nil drift["proposed_amount"]
    assert_equal "1100.0", drift["current_amount"]
    assert_nil drift["relative"]
  end

  test "scanning bumps neither lock_version nor updated_at" do
    assumption = linked_assumption(amount: 1100)
    @derivation.stubs(:salary_proposal).returns(proposal(amount: "1340"))

    assert_no_changes -> { assumption.reload.lock_version } do
      assert_no_changes -> { assumption.reload.updated_at } do
        scan!
      end
    end
    assert_equal "drifted", assumption.reload.drift["status"]
  end

  test "stores the key the scan ran under on the plan" do
    linked_assumption(amount: 1100)
    @derivation.stubs(:salary_proposal).returns(proposal(amount: "1340"))

    scan!

    assert_equal Forecasts::Drift.scan_key(@plan), @plan.reload.drift_scan_key
  end

  private
    def linked_assumption(amount:, kind: "salary", **attrs)
      defaults = {
        family: @family,
        kind: kind,
        name: kind.humanize,
        status: :active,
        origin: :source_derived,
        amount: amount,
        currency: "USD",
        source_record_type: "RecurringTransaction",
        source_record_id: SecureRandom.uuid,
        params: { "frequency" => "monthly" }
      }
      @plan.forecast_assumptions.create!(defaults.merge(attrs))
    end

    def proposal(amount:, status: :ok)
      OpenStruct.new(status: status, amount: amount && BigDecimal(amount))
    end

    def scan!
      Forecasts::Drift::Scanner.new(plan: @plan, as_of: @as_of).scan!
    end
end
