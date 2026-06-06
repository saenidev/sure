# frozen_string_literal: true

module Forecasts
  module Assumptions
    # Forecast V2 typed params value object for the `living_expense` assumption
    # kind (spec "Assumption Params Contracts"). Immutable, schema-validated
    # carrier produced by LivingExpenseForm — never an arbitrary hash. Money is
    # held as BigDecimal and serialized as a decimal string (never a float).
    #
    # living_expense is backend-derived in the MVP (no interactive editor yet),
    # but the bootstrap path may save/validate it, so the params contract still
    # exists. This object does NOT validate or coerce; the form owns that.
    class LivingExpenseParams
      SCHEMA_VERSION = 1

      attr_reader :amount, :currency, :frequency, :category_ids,
                  :inflation_policy, :inflation_rate, :actualization_policy,
                  :start_anchor, :end_anchor

      def initialize(
        amount:,
        currency:,
        frequency:,
        category_ids:,
        inflation_policy:,
        actualization_policy:,
        start_anchor:,
        end_anchor:,
        inflation_rate: nil
      )
        @amount = amount
        @currency = currency
        @frequency = frequency
        @category_ids = Array(category_ids)
        @inflation_policy = inflation_policy
        @inflation_rate = inflation_rate
        @actualization_policy = actualization_policy
        @start_anchor = start_anchor
        @end_anchor = end_anchor
      end

      # String-keyed, JSON-safe hash for persistence in Assumption#params.
      def to_h
        {
          "schema_version" => SCHEMA_VERSION,
          "amount" => decimal_string(amount),
          "currency" => currency,
          "frequency" => frequency,
          "category_ids" => category_ids,
          "inflation_policy" => inflation_policy,
          "inflation_rate" => decimal_string(inflation_rate),
          "actualization_policy" => actualization_policy,
          "start_anchor" => start_anchor,
          "end_anchor" => end_anchor
        }
      end

      private
        def decimal_string(value)
          return nil if value.nil?

          value.to_s("F")
        end
    end
  end
end
