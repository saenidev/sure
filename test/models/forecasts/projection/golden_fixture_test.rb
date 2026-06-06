# frozen_string_literal: true

require "test_helper"
require "json"

# Golden-fixture test for the pure projection engine.
#
# A golden fixture serializes one full engine input packet plus the engine
# output that must stay stable: `engine_version`, `schema_version`,
# `input_packet_hash`, expected per-period metrics, trace count, representative
# trace IDs, and issue codes. Small, silent changes in calculation semantics
# erode trust, so this fixture asserts the recorded values exactly.
#
# IMPORTANT: this is NOT a blind snapshot. The fixture file is hand-reviewed.
# When the engine's semantics change on purpose, a maintainer regenerates and
# REVIEWS the expected values intentionally (spec "Golden Fixture Catalog":
# "Golden fixture expected outputs should be reviewed intentionally when engine
# semantics change. Do not update them as a blind snapshot refresh."). A failure
# here means the projection contract moved — confirm it was intentional before
# touching the fixture.
#
# Covers the `baseline_salary_living_expenses` row of the Golden Fixture
# Catalog: salary, living expense, monthly cash, net worth.
class Forecasts::Projection::GoldenFixtureTest < ActiveSupport::TestCase
  FIXTURE_PATH = Rails.root.join(
    "test/fixtures/files/forecasts/baseline_salary_living_expenses.json"
  )

  setup do
    @fixture = JSON.parse(File.read(FIXTURE_PATH), symbolize_names: true)
    @expected = @fixture[:expected]
    @packet = Forecasts::Projection::Packet.new(@fixture[:input])
    @result = Forecasts::Projection::Engine.call(@packet)
  end

  # --- Versions ------------------------------------------------------------

  test "engine and schema versions match the golden fixture" do
    assert_equal @expected[:engine_version], @result.engine_version, review_message
    assert_equal @expected[:schema_version], @result.schema_version, review_message
  end

  # --- Input packet hash ---------------------------------------------------

  test "input packet hash matches the golden fixture" do
    # The packet recomputes its hash from the canonicalized input, so a stable
    # hash proves the recorded input shape and the hashing contract are intact.
    assert_equal @expected[:input_packet_hash], @packet.input_packet_hash, review_message
    assert_equal @expected[:input_packet_hash], @result.input_packet_hash, review_message
  end

  test "source snapshot and scenario stack hashes match the golden fixture" do
    assert_equal @expected[:source_snapshot_hash], @result.source_snapshot_hash, review_message
    assert_equal @expected[:scenario_stack_hash], @result.scenario_stack_hash, review_message
  end

  # --- Status + counts -----------------------------------------------------

  test "status, plan version, and counts match the golden fixture" do
    assert_equal @expected[:status], @result.status, review_message
    assert_equal @expected[:plan_version], @result.plan_version, review_message
    assert_equal @expected[:period_count], @result.periods.length, review_message
    assert_equal @expected[:trace_count], @result.traces.length, review_message
  end

  # --- Period metrics ------------------------------------------------------

  test "first period metrics match the golden fixture" do
    first = @result.periods.first

    assert_equal @expected[:first_period][:key], first[:key], review_message
    assert_equal @expected[:first_period][:metrics], first[:metrics], review_message
  end

  test "last period metrics match the golden fixture" do
    last = @result.periods.last

    assert_equal @expected[:last_period][:key], last[:key], review_message
    assert_equal @expected[:last_period][:metrics], last[:metrics], review_message
  end

  # --- Representative traces -----------------------------------------------

  test "representative trace ids and fields match the golden fixture" do
    @expected[:representative_traces].each do |expected_trace|
      actual = @result.traces.find { |trace| trace.id == expected_trace[:id] }

      refute_nil actual, "golden trace #{expected_trace[:id]} not found; #{review_message}"
      assert_equal expected_trace[:category], actual.category, review_message
      assert_equal expected_trace[:amount], actual.amount, review_message
      assert_equal expected_trace[:currency], actual.currency, review_message
      assert_equal expected_trace[:direction], actual.direction, review_message
      assert_equal expected_trace[:period_key], actual.period_key, review_message
      assert_equal expected_trace[:assumption_id], actual.assumption_id, review_message
    end
  end

  # --- Issue codes ---------------------------------------------------------

  test "issue codes match the golden fixture" do
    assert_equal @expected[:issue_codes], @result.issues.map(&:code), review_message
  end

  private
    # Shared failure message that nudges the maintainer toward intentional
    # review instead of a reflexive snapshot refresh.
    def review_message
      "Golden fixture mismatch. The engine output diverged from " \
      "#{FIXTURE_PATH.relative_path_from(Rails.root)}. If this change is " \
      "intentional, regenerate AND review the expected values on purpose; " \
      "do not refresh the fixture blindly."
    end
end
