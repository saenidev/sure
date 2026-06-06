# frozen_string_literal: true

module Forecasts
  # Forecast V2 read model for one plan/source issue. Answers exactly ONE UI
  # question: "what issue should the user understand and remediate?"
  #
  # It is a pure presenter over a single Forecasts::Projection::PlanIssue value
  # object (or an equivalent plain hash). It never calls the engine, never
  # mutates records, and never queries the database — it reformats one already
  # built issue into a privacy-safe, user-facing payload (spec "Read Model
  # Contracts", "Issue Code Catalog").
  #
  # Privacy contract (spec: "Must not include raw exception text, UUID-first
  # messages, account names the user cannot access"):
  #   - the payload surfaces the localized title (`display_name`), the affected
  #     output, severity, impact summary, the i18n `message_key`, and remediation
  #     `actions` only.
  #   - it NEVER surfaces `debug_context`, raw `affected_entity_id` UUIDs, or any
  #     low-level diagnostics. Those stay on the engine value object for logs.
  class IssueReadModel
    attr_reader :code, :severity, :source, :period, :title, :affected_output,
      :impact, :message_key, :actions

    # `issue` is a Forecasts::Projection::PlanIssue or a plain hash with the same
    # keys (e.g. a deserialized issue). Either way only the user-facing,
    # privacy-safe fields are read; debug context and raw entity ids are dropped.
    def initialize(issue:)
      attrs = coerce(issue)

      @code = attrs[:code]
      @severity = attrs[:severity]
      @source = attrs[:source]
      @period = attrs[:period]
      @title = attrs[:display_name]
      @affected_output = attrs[:display_name]
      @impact = attrs[:impact]
      @message_key = attrs[:message_key]
      @actions = Array(attrs[:actions]).map(&:to_s)
    end

    # Typed, privacy-safe UI payload. No UUIDs, no debug context, no raw
    # exception text — only the localizable, user-facing fields.
    def to_h
      {
        code: code,
        severity: severity,
        source: source,
        period: period,
        title: title,
        affected_output: affected_output,
        impact: impact,
        message_key: message_key,
        actions: actions
      }
    end

    private
      def coerce(issue)
        if issue.is_a?(Forecasts::Projection::PlanIssue)
          {
            code: issue.code,
            severity: issue.severity,
            source: issue.source,
            period: issue.period,
            display_name: issue.display_name,
            impact: issue.impact,
            message_key: issue.message_key,
            actions: issue.actions
          }
        else
          Forecasts::Projection.deep_symbolize(issue)
        end
      end
  end
end
