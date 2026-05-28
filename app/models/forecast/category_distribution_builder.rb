module Forecast
  class CategoryDistributionBuilder
    Result = Data.define(:low, :expected, :high, :source, :risk_flags)

    def initialize(category:, expected_amount:)
      @category = category
      @expected_amount = expected_amount.to_d
    end

    def call
      if expected_amount.zero?
        return Result.new(low: 0.to_d, expected: 0.to_d, high: 0.to_d, source: "zero_expected", risk_flags: [])
      end

      Result.new(
        low: (expected_amount * 0.85).round(4),
        expected: expected_amount,
        high: (expected_amount * 1.15).round(4),
        source: "budget_variance_fallback",
        risk_flags: [
          {
            "type" => "distribution_estimated_from_budget",
            "category_id" => category&.id,
            "reason" => "historical_category_distribution_not_yet_modeled"
          }
        ]
      )
    end

    private
      attr_reader :category, :expected_amount
  end
end
