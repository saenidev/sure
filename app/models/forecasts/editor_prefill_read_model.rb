# frozen_string_literal: true

module Forecasts
  # Forecast V2 read model for opening one typed editor. Answers exactly ONE UI
  # question: "what does one typed editor need to open?"
  #
  # It consumes a single Forecasts::Assumption record (already loaded) plus its
  # optional scenario-layer context. It returns one typed editor payload — the
  # form key, current values, collapsed-section summaries, validation metadata,
  # and scenario context — and nothing else. It must NOT include other
  # assumptions, chart series, or projection-result bodies (spec "Read Model
  # Contracts", "UI Payload Contracts"). It never calls the engine, mutates
  # records, or queries the database.
  #
  # The optimistic `lock_version` rides in the validation metadata so the save
  # endpoint can reject stale edits (spec "Form Objects": "stale lock/version
  # conflicts").
  class EditorPrefillReadModel
    # Editor schema version. Bumped when the typed editor payload shape changes so
    # a stale client can detect a migration boundary.
    VALIDATION_SCHEMA_VERSION = 1

    attr_reader :assumption, :scenario_layer_id

    def initialize(assumption:, scenario_layer_id: nil)
      @assumption = assumption
      @scenario_layer_id = scenario_layer_id
    end

    def to_h
      {
        form_key: assumption.kind,
        assumption_id: assumption.id,
        scenario_layer_id: scenario_layer_id,
        primary_values: primary_values,
        section_summaries: section_summaries,
        validation: validation
      }
    end

    private
      # The current editable values for the form's primary fields. Money stays a
      # decimal string; params ride through as the typed form's raw inputs.
      def primary_values
        {
          name: assumption.name,
          amount: assumption.amount&.to_s,
          currency: assumption.currency,
          starts_on: assumption.starts_on&.iso8601,
          ends_on: assumption.ends_on&.iso8601,
          params: assumption.params || {}
        }
      end

      # Collapsed-section summaries shown before the user expands each editor
      # section. i18n keys + raw values only — the client formats them.
      def section_summaries
        {
          time_range: {
            key: "forecasts.editor.time_range",
            starts_on: assumption.starts_on&.iso8601,
            ends_on: assumption.ends_on&.iso8601
          },
          change_over_time: {
            key: "forecasts.editor.change_over_time",
            growth_rate: params["growth_rate"],
            inflation_rate: params["inflation_rate"]
          },
          source: {
            key: "forecasts.editor.source",
            origin: assumption.origin,
            review_state: assumption.review_state
          }
        }
      end

      # Validation metadata: the optimistic lock version for stale-edit detection
      # plus the editor schema version. No projection bodies, no other records.
      def validation
        {
          lock_version: assumption.lock_version,
          schema_version: VALIDATION_SCHEMA_VERSION
        }
      end

      def params
        assumption.params || {}
      end
  end
end
