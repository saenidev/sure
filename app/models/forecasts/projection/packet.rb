# frozen_string_literal: true

module Forecasts
  module Projection
    # The validated plan packet: the single engine input contract. Pure value
    # object, no ActiveRecord. The engine accepts only this; it never receives
    # models, relations, params, or family/user objects. Invalid shapes raise a
    # typed error before simulation starts. The packet is deterministic and safe
    # to store with snapshots: the same packet + engine version yields the same
    # result. See spec "Plan Packet" and "Engine Contract Envelope".
    class Packet
      InvalidPacketError = Class.new(ArgumentError)

      attr_reader :schema_version, :engine_version, :plan, :scenario_stack,
        :milestones, :assumptions, :scenario_operations, :source_snapshot,
        :issue_policy, :input_packet_hash, :source_snapshot_hash,
        :scenario_stack_hash

      def initialize(attributes)
        attrs = Forecasts::Projection.deep_symbolize(attributes)

        @schema_version = attrs[:schema_version]
        @engine_version = attrs[:engine_version]
        @plan = Forecasts::Projection.deep_freeze(attrs[:plan] || {})
        @scenario_stack = Forecasts::Projection.deep_freeze(attrs[:scenario_stack] || {})
        @milestones = Forecasts::Projection.deep_freeze(Array(attrs[:milestones]))
        @assumptions = Forecasts::Projection.deep_freeze(Array(attrs[:assumptions]))
        @scenario_operations = Forecasts::Projection.deep_freeze(Array(attrs[:scenario_operations]))
        @source_snapshot = Forecasts::Projection.deep_freeze(attrs[:source_snapshot] || {})
        @issue_policy = Forecasts::Projection.deep_freeze(attrs[:issue_policy] || {})

        validate!

        # Hashes are computed eagerly so the packet can be deeply frozen. The
        # recompute coordinator keys caches on these (with plan_version and
        # engine_version) for stale-result protection.
        @input_packet_hash = Forecasts::Projection.stable_hash(to_h)
        @source_snapshot_hash = Forecasts::Projection.stable_hash(source_snapshot)
        @scenario_stack_hash = Forecasts::Projection.stable_hash(scenario_stack)

        freeze
      end

      def to_h
        {
          schema_version: schema_version,
          engine_version: engine_version,
          plan: plan,
          scenario_stack: scenario_stack,
          milestones: milestones,
          assumptions: assumptions,
          scenario_operations: scenario_operations,
          source_snapshot: source_snapshot,
          issue_policy: issue_policy
        }
      end

      private
        def validate!
          missing = []
          missing << "schema_version" if schema_version.nil?
          missing << "engine_version" if blank?(engine_version)
          unless missing.empty?
            raise InvalidPacketError, "Packet missing required fields: #{missing.join(', ')}"
          end

          validate_plan!
          validate_scenario_stack!
          validate_source_snapshot!
        end

        def validate_plan!
          missing = []
          missing << "plan.id" if blank?(plan[:id])
          missing << "plan.family_id" if blank?(plan[:family_id])
          missing << "plan.reporting_currency" if blank?(plan[:reporting_currency])

          horizon = plan[:horizon] || {}
          missing << "plan.horizon.starts_on" if blank?(horizon[:starts_on])
          missing << "plan.horizon.ends_on" if blank?(horizon[:ends_on])

          return if missing.empty?

          raise InvalidPacketError, "Packet missing required fields: #{missing.join(', ')}"
        end

        def validate_scenario_stack!
          return unless blank?(scenario_stack[:key])

          raise InvalidPacketError, "Packet missing required fields: scenario_stack.key"
        end

        def validate_source_snapshot!
          return unless blank?(source_snapshot[:as_of])

          raise InvalidPacketError, "Packet missing required fields: source_snapshot.as_of"
        end

        def blank?(value)
          value.nil? || (value.respond_to?(:empty?) && value.empty?)
        end
    end
  end
end
