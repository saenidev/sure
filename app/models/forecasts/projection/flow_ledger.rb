# frozen_string_literal: true

require "bigdecimal"

module Forecasts
  module Projection
    # The flow ledger is the normalized, ordered list of dated financial effects
    # produced by assumption expansion. It is the shared representation period
    # simulation reads and that the UI uses to explain causes consistently. Pure
    # value object: no ActiveRecord, no providers, deterministic for the same
    # input. Money is carried as decimal strings plus a currency context, never
    # floats. See spec "Flow Ledger" and "Assumption Expansion".
    class FlowLedger
      # One dated effect on the ledger. Expanders build these; the ledger orders
      # and exposes them. Each flow links back to the assumption and scenario
      # layer that produced it so traces can be derived deterministically.
      #
      # `category` is the ledger effect category (income/spending for this
      # proof slice) and maps directly onto the Trace contract categories.
      class Flow
        # Ledger effect categories. Scoped to the kinds this slice expands
        # (income + spending); the catalog grows with later expanders. These are
        # a subset of `Forecasts::Projection::Trace::CATEGORIES`.
        CATEGORIES = %w[income spending].freeze
        DIRECTIONS = %w[inflow outflow].freeze

        InvalidFlowError = Class.new(ArgumentError)

        attr_reader :date, :amount, :currency, :category, :direction,
          :source_kind, :assumption_id, :scenario_layer_id, :flow_key,
          :sequence, :metadata

        # rubocop:disable Metrics/ParameterLists
        def initialize(date:, amount:, currency:, category:, direction:,
                       source_kind:, assumption_id:, flow_key:,
                       scenario_layer_id: nil, sequence: 0, metadata: {})
          # Money must never be a float — guard the decimal-string contract at
          # the boundary, mirroring Forecasts::Projection::Trace.
          if amount.is_a?(Float)
            raise InvalidFlowError,
              "Flow amount must be a decimal string, not Float (#{amount.inspect})"
          end

          @date = date.is_a?(Date) ? date : Date.parse(date.to_s)
          @amount = amount.to_s
          @currency = currency
          @category = category.to_s
          @direction = direction.to_s
          @source_kind = source_kind.to_s
          @assumption_id = assumption_id
          @scenario_layer_id = scenario_layer_id
          @flow_key = flow_key
          @sequence = sequence
          @metadata = Forecasts::Projection.deep_freeze(
            Forecasts::Projection.deep_symbolize(metadata || {})
          )

          validate!
          freeze
        end
        # rubocop:enable Metrics/ParameterLists

        # Period key (YYYY-MM) the flow falls into. A flow dated on a period
        # boundary belongs to the period containing that date.
        def period_key
          format("%04d-%02d", date.year, date.month)
        end

        # --- Convenience readers over kind-specific trace metadata ----------
        # These surface the metadata fields read models and traces care about
        # without callers reaching into the raw hash. They return nil/[] when a
        # given expander does not populate them.

        # Salary gross/net interpretation.
        def gross_amount = metadata[:gross_amount]
        def net_amount = metadata[:net_amount]
        def gross_or_net = metadata[:gross_or_net]

        # Living-expense category rollup.
        def category_ids
          Array(metadata[:category_ids])
        end

        def to_h
          {
            flow_key: flow_key,
            date: date.iso8601,
            period_key: period_key,
            amount: amount,
            currency: currency,
            category: category,
            direction: direction,
            source_kind: source_kind,
            assumption_id: assumption_id,
            scenario_layer_id: scenario_layer_id,
            sequence: sequence,
            # Common kind-specific trace fields surfaced flat so downstream
            # trace/read-model code does not reach into the metadata hash.
            gross_amount: gross_amount,
            net_amount: net_amount,
            gross_or_net: gross_or_net,
            category_ids: category_ids,
            metadata: metadata
          }
        end

        private
          def validate!
            unless CATEGORIES.include?(category)
              raise InvalidFlowError,
                "Flow category must be one of #{CATEGORIES.join(', ')} (got #{category.inspect})"
            end

            unless DIRECTIONS.include?(direction)
              raise InvalidFlowError,
                "Flow direction must be one of #{DIRECTIONS.join(', ')} (got #{direction.inspect})"
            end

            return if @amount.match?(/\A-?\d+(\.\d+)?\z/)

            raise InvalidFlowError,
              "Flow amount must be a decimal string (got #{amount.inspect})"
          end
      end

      attr_reader :flows

      def initialize(flows = [])
        @flows = order(Array(flows)).freeze
        freeze
      end

      # Append flows (e.g. from another expander) and return a new ledger so the
      # value object stays immutable.
      def merge(more_flows)
        self.class.new(flows + Array(more_flows))
      end

      def empty?
        flows.empty?
      end

      def size
        flows.length
      end

      def each(&block)
        flows.each(&block)
      end

      include Enumerable

      def for_period(period_key)
        flows.select { |flow| flow.period_key == period_key }
      end

      def to_a
        flows.map(&:to_h)
      end

      private
        # Deterministic ordering: by date, then by the spec's intra-period flow
        # order (income before spending), then by an explicit sequence and the
        # stable flow key as a final tiebreaker. This makes period simulation
        # reproducible regardless of expander invocation order.
        def order(input)
          input.sort_by do |flow|
            [
              flow.date,
              category_rank(flow.category),
              flow.sequence,
              flow.flow_key.to_s
            ]
          end
        end

        # Intra-period ordering from spec "Flow Ordering": income applies before
        # spending. Lower rank applies first.
        def category_rank(category)
          case category
          when "income" then 1
          when "spending" then 4
          else 99
          end
        end
    end
  end
end
