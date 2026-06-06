# frozen_string_literal: true

module Forecasts
  module Assumptions
    # Forecast V2 typed params value object for the `salary` assumption kind
    # (spec "Assumption Params Contracts"). Immutable, schema-validated carrier
    # produced by SalaryForm — never an arbitrary hash. Money is held as
    # BigDecimal and serialized as a decimal string (never a float) so the pure
    # engine can rehydrate deterministic decimal math.
    #
    # This object does NOT validate or coerce; the form owns that. It only holds
    # already-coerced, already-validated values and serializes them.
    class SalaryParams
      SCHEMA_VERSION = 1

      attr_reader :person_key, :amount, :gross_or_net, :currency, :frequency,
                  :growth_policy, :growth_rate, :net_ratio, :cash_account_id,
                  :start_anchor, :end_anchor

      def initialize(
        person_key:,
        amount:,
        gross_or_net:,
        currency:,
        frequency:,
        growth_policy:,
        start_anchor:,
        end_anchor:,
        growth_rate: nil,
        net_ratio: nil,
        cash_account_id: nil
      )
        @person_key = person_key
        @amount = amount
        @gross_or_net = gross_or_net
        @currency = currency
        @frequency = frequency
        @growth_policy = growth_policy
        @growth_rate = growth_rate
        @net_ratio = net_ratio
        @cash_account_id = cash_account_id
        @start_anchor = start_anchor
        @end_anchor = end_anchor
      end

      # String-keyed, JSON-safe hash for persistence in Assumption#params. Money
      # and rates serialize as decimal strings; anchors keep their normalized
      # {type:, ...} shape so the engine resolves them deterministically.
      #
      # `net_ratio` is only emitted when set so a plain net salary (the common
      # case) keeps an unchanged params shape and existing/derived salaries are
      # byte-identical. When present it is the gross→take-home fraction the engine
      # applies to a gross salary's cash impact.
      def to_h
        hash = {
          "schema_version" => SCHEMA_VERSION,
          "person_key" => person_key,
          "amount" => decimal_string(amount),
          "gross_or_net" => gross_or_net,
          "currency" => currency,
          "frequency" => frequency,
          "growth_policy" => growth_policy,
          "growth_rate" => decimal_string(growth_rate),
          "cash_account_id" => cash_account_id,
          "start_anchor" => start_anchor,
          "end_anchor" => end_anchor
        }
        hash["net_ratio"] = decimal_string(net_ratio) unless net_ratio.nil?
        hash
      end

      private
        def decimal_string(value)
          return nil if value.nil?

          value.to_s("F")
        end
    end
  end
end
