# Regenerates the `expected` section of every dual-engine parity fixture in
# test/fixtures/files/forecasts/parity/ by running the RUBY engine over each
# fixture's `input` packet. The Ruby engine is the source of truth; the JS
# preview engine is compared against these outputs within the parity budget
# (spec §11a). `_comment` and `input` round-trip untouched — only `expected`
# is rewritten — so a fixture's scenario can never drift while regenerating.
#
# The emitted period rows mirror exactly how RecomputeCoordinator persists
# active assumption ids (trace rows grouped by period, compact/uniq/sorted by
# to_s) so the fixtures and the persisted cache agree on activity semantics.
#
# Run with:
#   RAILS_ENV=test bundle exec rake forecast:parity:regenerate
# then HAND-REVIEW the diff — never refresh blindly (golden-fixture rule).
namespace :forecast do
  namespace :parity do
    desc "Regenerate expected outputs for the dual-engine parity fixtures"
    task regenerate: :environment do
      dir = Rails.root.join("test/fixtures/files/forecasts/parity")

      Dir[dir.join("*.json").to_s].sort.each do |path|
        fixture = JSON.parse(File.read(path), symbolize_names: true)
        packet = Forecasts::Projection::Packet.new(fixture[:input])
        result = Forecasts::Projection::Engine.call(packet)

        # A parity fixture must be a clean run — an issue-bearing fixture
        # would bake engine fallbacks into the cross-engine truth.
        unless result.issues.empty?
          raise "#{File.basename(path)}: engine reported issues " \
                "#{result.issues.map(&:code).inspect} — fix the input, " \
                "parity fixtures must be clean runs"
        end

        trace_rows = result.trace_rows || result.traces
        ids_by_period = trace_rows.group_by(&:period_key).transform_values do |traces|
          traces.map(&:assumption_id).compact.uniq.sort_by(&:to_s)
        end

        periods = result.periods
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

        fixture[:expected] = { period_count: periods.length, periods: periods }
        File.write(path, JSON.pretty_generate(fixture) + "\n")
        puts "#{File.basename(path)}: #{periods.length} periods"
      end
    end
  end
end
