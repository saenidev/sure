require "digest"

module Forecast
  class ScenarioStack
    Result = Data.define(:key, :scenario_ids, :snapshot, :risk_flags)

    def initialize(family:, scenario_ids:)
      @family = family
      @scenario_ids = Array(scenario_ids).compact_blank
    end

    def call
      ordered = scenarios.sort_by { |scenario| [ scenario.starts_on || Date.new(9999, 12, 31), scenario.position || 0, scenario.id ] }
      ids = ordered.map(&:id)
      missing_ids = scenario_ids - ids
      raise ArgumentError, "Unknown or inactive forecast scenario ids: #{missing_ids.join(", ")}" if missing_ids.any?

      key = ids.empty? ? "baseline" : Digest::SHA256.hexdigest(ids.join(":")).first(16)

      Result.new(
        key: key,
        scenario_ids: ids,
        snapshot: {
          "key" => key,
          "scenario_ids" => ids,
          "scenarios" => ordered.map { |scenario| snapshot_for(scenario) }
        },
        risk_flags: []
      )
    end

    private
      attr_reader :family, :scenario_ids

      def scenarios
        @scenarios ||= family.forecast_scenarios.active.where(id: scenario_ids)
      end

      def snapshot_for(scenario)
        {
          "id" => scenario.id,
          "name" => scenario.name,
          "position" => scenario.position,
          "starts_on" => scenario.starts_on&.iso8601,
          "ends_on" => scenario.ends_on&.iso8601,
          "approval_status" => scenario.approval_status
        }
      end
  end
end
