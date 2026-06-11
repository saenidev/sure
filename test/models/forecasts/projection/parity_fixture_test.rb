# frozen_string_literal: true

require "test_helper"
require "json"

# Exact-match guard over the dual-engine parity fixtures (spec §11a).
#
# Each fixture in test/fixtures/files/forecasts/parity/ stores a full engine
# input packet plus the Ruby-generated monthly series. This test re-runs the
# RUBY engine and asserts the recorded `expected` matches EXACTLY — period
# count, every period's key/start/metrics/active assumption ids — so the
# fixtures can never silently drift from the Ruby engine. The node parity
# suite (test/javascript/preview_engine_parity.test.mjs) then compares the JS
# preview engine against the same `expected` within the parity budget; with
# this guard in place, that comparison is transitively a Ruby-vs-JS check.
#
# Like the golden fixture, `expected` is hand-reviewed: regenerate via
# `rake forecast:parity:regenerate` and REVIEW the diff intentionally.
class Forecasts::Projection::ParityFixtureTest < ActiveSupport::TestCase
  PARITY_DIR = Rails.root.join("test/fixtures/files/forecasts/parity")

  # One test per fixture file, defined at class-body load so a new fixture is
  # covered the moment it lands in the directory.
  Dir[PARITY_DIR.join("*.json").to_s].sort.each do |path|
    fixture_name = File.basename(path, ".json")

    test "#{fixture_name} expected series matches the Ruby engine exactly" do
      fixture = JSON.parse(File.read(path), symbolize_names: true)
      packet = Forecasts::Projection::Packet.new(fixture[:input])
      result = Forecasts::Projection::Engine.call(packet)

      # Parity fixtures must be clean runs — issues would bake engine
      # fallback behavior into the cross-engine truth.
      assert_empty result.issues, review_message(path)

      # Mirror RecomputeCoordinator's persisted activity semantics: trace
      # rows grouped by period, ids compact/uniq/sorted by to_s.
      trace_rows = result.trace_rows || result.traces
      ids_by_period = trace_rows.group_by(&:period_key).transform_values do |traces|
        traces.map(&:assumption_id).compact.uniq.sort_by(&:to_s)
      end

      actual = result.periods
        .select { |period| period[:granularity].to_s == "month" }
        .sort_by { |period| period[:starts_on].to_s }
        .map do |period|
          {
            k: period[:key],
            s: period[:starts_on],
            m: period[:metrics],
            active_assumption_ids: ids_by_period.fetch(period[:key], [])
          }
        end

      expected = fixture[:expected]
      assert_equal expected[:periods].length, expected[:period_count],
        "fixture is self-inconsistent (period_count != periods.length) — #{review_message(path)}"
      assert_equal expected[:period_count], actual.length, review_message(path)
      expected[:periods].each_with_index do |expected_period, i|
        assert_equal expected_period, actual[i],
          "period #{i} (#{expected_period[:k]}) diverged — #{review_message(path)}"
      end
    end
  end

  private
    def review_message(path)
      "Parity fixture mismatch in #{Pathname.new(path).relative_path_from(Rails.root)}. " \
      "If the engine change is intentional, run `rake forecast:parity:regenerate` " \
      "AND review the expected values on purpose; do not refresh blindly."
    end
end
