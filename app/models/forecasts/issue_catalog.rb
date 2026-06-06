# frozen_string_literal: true

module Forecasts
  # Forecast V2 stable issue-code catalog (spec "Issue Code Catalog").
  #
  # The first-viewport issue PANEL is fed from the projection cache's privacy-safe
  # issue SUMMARY, which stores only issue CODES (counts + codes, no financial
  # detail and no per-issue rows — spec "Render plan issues: no per-issue queries").
  # To render a STRUCTURED, human issue (localized title + severity + remediation
  # actions) from a bare code without a per-issue query, the panel needs the stable
  # code -> {severity, message_key, actions} mapping that is part of the engine/UI
  # contract. This module is that mapping.
  #
  # It is a pure, deterministic lookup (no I/O, no Current.*, no Date.current): the
  # caller hands a code and gets back the privacy-safe presentation fields the
  # IssueReadModel needs. The visible title is the localized `message_key`, NEVER
  # the raw code or a raw entity id (spec "Error And Issue UX": "Raw UUIDs and
  # engine-internal identifiers should not appear in user-facing failures"; the code
  # stays a non-visible identifier for tests/assistive tech).
  module IssueCatalog
    module_function

    # code => { severity:, actions: } from the spec "Issue Code Catalog". The
    # message_key is derived (`forecasts.issues.<code>`) so adding a code only needs
    # a locale entry. Severities mirror the catalog's Severity column.
    ENTRIES = {
      "missing_fx_rate" => {
        severity: "error",
        actions: %w[fetch_rates enter_fallback_rate exclude_account change_reporting_currency]
      },
      "missing_security_price" => {
        severity: "error",
        actions: %w[fetch_prices enter_fallback_price exclude_holding]
      },
      "stale_source_data" => {
        severity: "warning",
        actions: %w[refresh_source_data]
      },
      "insufficient_history" => {
        severity: "warning",
        actions: %w[add_assumption]
      },
      "missing_debt_terms" => {
        severity: "error",
        actions: %w[add_debt_terms exclude_account]
      },
      "invalid_assumption_params" => {
        severity: "blocking",
        actions: %w[fix_fields]
      },
      "unknown_assumption_kind" => {
        severity: "blocking",
        actions: %w[remove_assumption]
      },
      "account_rule_conflict" => {
        severity: "warning",
        actions: %w[edit_account_rules]
      },
      "scenario_layer_conflict" => {
        severity: "warning",
        actions: %w[reorder_layers]
      }
    }.freeze

    DEFAULT_SEVERITY = "warning"

    # The privacy-safe presentation fields for one issue code, shaped for
    # `IssueReadModel.new(issue: ...)`. `display_name` is intentionally nil so the
    # panel renders the localized `message_key` title (never the raw code). Unknown
    # codes still render structurally (localized message_key, no actions) rather
    # than leaking the raw code as the only signal.
    def issue_hash(code, source: "projection", period: nil)
      entry = ENTRIES.fetch(code.to_s, nil)
      {
        code: code.to_s,
        severity: entry ? entry[:severity] : DEFAULT_SEVERITY,
        source: source,
        period: period,
        display_name: nil,
        message_key: "forecasts.issues.#{code}",
        impact: nil,
        actions: entry ? entry[:actions] : []
      }
    end
  end
end
