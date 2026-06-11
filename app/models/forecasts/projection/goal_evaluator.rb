# frozen_string_literal: true

module Forecasts
  module Projection
    # Goal evaluation runs after period simulation so goals can reference
    # projected balances, cash flows, debt levels, portfolio values, and dates.
    # This is the proof-slice STUB: it returns an empty/passthrough set of goal
    # statuses so the engine pipeline assembles end-to-end without goal math.
    # Later slices replace this with funding-gap, target-feasibility, and
    # blocking-assumption evaluation per spec "Goal Evaluation".
    #
    # Pure value object: no ActiveRecord, no providers, no clock. Goal-bearing
    # packets are accepted but produce no statuses yet; the contract (an array of
    # goal status hashes) is stable so downstream read models can rely on it.
    class GoalEvaluator
      attr_reader :goals, :periods, :reporting_currency

      def initialize(goals:, periods:, reporting_currency:)
        @goals = Array(goals)
        @periods = Array(periods)
        @reporting_currency = reporting_currency
      end

      # Returns goal status payloads. The proof slice has no goal evaluation, so
      # this is an empty passthrough regardless of input. The shape is an array
      # of plain hashes (cache/UI-ready), matching the Result `goals` contract.
      def evaluate
        []
      end
    end
  end
end
