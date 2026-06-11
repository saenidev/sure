# frozen_string_literal: true

require "digest"

module Forecasts
  module Projection
    # Pure value object for one structured engine/source finding. No
    # ActiveRecord. `debug_context` may carry IDs and low-level details, but the
    # UI renders `display_name`, `message_key`, `impact`, and `actions`. See spec
    # "Plan Issues" and "Issue Code Catalog".
    class PlanIssue
      InvalidIssueError = Class.new(ArgumentError)

      # Severities from the spec "Issue Code Catalog" / severity meanings.
      SEVERITIES = %w[blocking error warning info].freeze

      attr_reader :id, :code, :severity, :source, :period,
        :affected_entity_type, :affected_entity_id, :display_name,
        :message_key, :impact, :actions, :debug_context

      def initialize(attributes)
        attrs = Forecasts::Projection.deep_symbolize(attributes)

        @code = attrs[:code]
        @severity = attrs[:severity]
        @source = attrs[:source]
        @period = attrs[:period]
        @affected_entity_type = attrs[:affected_entity_type]
        @affected_entity_id = attrs[:affected_entity_id]
        @display_name = attrs[:display_name]
        @message_key = attrs[:message_key]
        @impact = attrs[:impact]
        @actions = Array(attrs[:actions]).map(&:to_s).freeze
        @debug_context = (attrs[:debug_context] || {}).freeze
        # A STABLE, opaque id derived from the issue's identifying facets
        # (code + period + affected entity), mirroring how Trace ids are derived
        # from their identifying facets. Period rows reference issues by this id,
        # so it must be stable across runs and independent of the issue's
        # position in any array (synthetic positional "issue-N" indexes broke
        # because the engine prepends expansion issues, shifting every offset).
        @id = attrs[:id] || derive_id

        validate!
        freeze
      end

      def to_h
        {
          id: id,
          code: code,
          severity: severity,
          source: source,
          period: period,
          affected_entity_type: affected_entity_type,
          affected_entity_id: affected_entity_id,
          display_name: display_name,
          message_key: message_key,
          impact: impact,
          actions: actions,
          debug_context: debug_context
        }
      end

      private
        # Stable issue key: code, period, and affected entity, hashed to a short,
        # opaque token (same shape as Trace ids). Determinism comes from the
        # identifying facets, so two engine runs over the same packet produce the
        # same id and period `issue_ids` join to real issues.
        def derive_id
          parts = [
            code,
            period,
            affected_entity_type,
            affected_entity_id
          ]
          "issue-#{Digest::SHA256.hexdigest(parts.join('|'))[0, 16]}"
        end

        def validate!
          missing = []
          missing << "code" if blank?(code)
          missing << "severity" if blank?(severity)
          missing << "source" if blank?(source)
          missing << "message_key" if blank?(message_key)
          unless missing.empty?
            raise InvalidIssueError, "PlanIssue missing required fields: #{missing.join(', ')}"
          end

          unless SEVERITIES.include?(severity.to_s)
            raise InvalidIssueError,
              "PlanIssue severity must be one of #{SEVERITIES.join(', ')} (got #{severity.inspect})"
          end
        end

        def blank?(value)
          value.nil? || (value.respond_to?(:empty?) && value.empty?)
        end
    end
  end
end
