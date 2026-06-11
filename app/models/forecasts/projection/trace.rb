# frozen_string_literal: true

module Forecasts
  module Projection
    # Pure value object for one traced flow contributing to a period metric.
    # Money is a decimal string plus a currency context, never a float. The
    # selected-period explanation is rendered from traces, not chart series. See
    # spec "Trace Contract".
    class Trace
      InvalidTraceError = Class.new(ArgumentError)

      # Trace categories from the spec "Trace Contract".
      CATEGORIES = %w[
        income
        spending
        transfer
        debt_service
        debt_interest
        portfolio_contribution
        portfolio_return
        asset_purchase
        asset_sale
        goal_funding
        actualized_transaction
        issue_impact
      ].freeze

      DIRECTIONS = %w[inflow outflow neutral].freeze

      attr_reader :id, :period_key, :source_type, :source_id, :assumption_id,
        :scenario_layer_id, :flow_id, :category, :amount, :currency,
        :direction, :display_name, :explanation_key, :source_record_refs

      # `presymbolized: true` is an internal fast path for builders that
      # certify the hash (and any nested refs) is already deeply symbolized —
      # re-walking every trace's attributes across ~9k traces on a 30-year plan
      # was a measurable slice of the engine perf budget. External callers
      # passing raw (possibly string-keyed) hashes use the default path.
      def initialize(attributes, presymbolized: false)
        attrs = presymbolized ? attributes : Forecasts::Projection.deep_symbolize(attributes)

        @id = attrs[:id]
        @period_key = attrs[:period_key]
        @source_type = attrs[:source_type]
        @source_id = attrs[:source_id]
        @assumption_id = attrs[:assumption_id]
        @scenario_layer_id = attrs[:scenario_layer_id]
        @flow_id = attrs[:flow_id]
        @category = attrs[:category]
        @amount = attrs[:amount]
        @currency = attrs[:currency]
        @direction = attrs[:direction]
        @display_name = attrs[:display_name]
        @explanation_key = attrs[:explanation_key]
        @source_record_refs = freeze_refs(attrs[:source_record_refs])

        validate!
        freeze
      end

      def to_h
        {
          id: id,
          period_key: period_key,
          source_type: source_type,
          source_id: source_id,
          assumption_id: assumption_id,
          scenario_layer_id: scenario_layer_id,
          flow_id: flow_id,
          category: category,
          amount: amount,
          currency: currency,
          direction: direction,
          display_name: display_name,
          explanation_key: explanation_key,
          source_record_refs: source_record_refs
        }
      end

      private
        def validate!
          missing = []
          missing << "id" if blank?(id)
          missing << "period_key" if blank?(period_key)
          missing << "category" if blank?(category)
          missing << "currency" if blank?(currency)
          missing << "direction" if blank?(direction)
          unless missing.empty?
            raise InvalidTraceError, "Trace missing required fields: #{missing.join(', ')}"
          end

          # Money must be a decimal string, never a float. This guards the
          # "money as decimal strings, never floats" contract at the boundary.
          unless amount.is_a?(String)
            raise InvalidTraceError,
              "Trace amount must be a decimal string, not #{amount.class} (#{amount.inspect})"
          end

          unless CATEGORIES.include?(category.to_s)
            raise InvalidTraceError,
              "Trace category must be one of #{CATEGORIES.join(', ')} (got #{category.inspect})"
          end

          unless DIRECTIONS.include?(direction.to_s)
            raise InvalidTraceError,
              "Trace direction must be one of #{DIRECTIONS.join(', ')} (got #{direction.inspect})"
          end
        end

        def freeze_refs(refs)
          # An already-frozen array (the builder shares one per assumption) is
          # used as-is instead of being re-walked and re-allocated per trace.
          return refs if refs.is_a?(Array) && refs.frozen?

          Array(refs).map { |ref| Forecasts::Projection.deep_freeze(ref) }.freeze
        end

        def blank?(value)
          value.nil? || (value.respond_to?(:empty?) && value.empty?)
        end
    end
  end
end
