# frozen_string_literal: true

# Forecast V2 typed assumption (salary, living_expense, etc.). Family-scoped both
# directly (family_id) and through its plan. Carries provenance/review metadata
# and an optimistic lock so stale edits are rejected. No projection logic here —
# typed value/form objects and the pure engine live elsewhere.
module Forecasts
  class Assumption < ApplicationRecord
    self.table_name = "forecast_assumptions"

    belongs_to :forecast_plan,
      class_name: "Forecasts::Plan",
      inverse_of: :forecast_assumptions
    belongs_to :family
    belongs_to :starts_at_milestone,
      class_name: "Forecasts::Milestone",
      inverse_of: :starting_assumptions,
      optional: true
    belongs_to :ends_at_milestone,
      class_name: "Forecasts::Milestone",
      inverse_of: :ending_assumptions,
      optional: true

    has_many :forecast_scenario_layer_assumptions,
      class_name: "Forecasts::ScenarioLayerAssumption",
      foreign_key: :forecast_assumption_id,
      inverse_of: :forecast_assumption,
      dependent: :destroy
    has_many :scenario_layers,
      through: :forecast_scenario_layer_assumptions,
      source: :forecast_scenario_layer

    # `scopes: false` keeps generated values (e.g. `sample`, `high`, `low`) from
    # shadowing ActiveRecord::Relation methods; predicate readers like `active?`
    # are still available.
    enum :status, {
      active: "active",
      draft: "draft",
      disabled: "disabled",
      archived: "archived"
    }, default: :active, validate: true, scopes: false

    enum :origin, {
      user_created: "user_created",
      source_derived: "source_derived",
      system_default: "system_default",
      sample: "sample"
    }, default: :user_created, validate: true, scopes: false

    enum :confidence, {
      high: "high",
      medium: "medium",
      low: "low"
    }, validate: { allow_nil: true }, scopes: false

    enum :review_state, {
      confirmed: "confirmed",
      needs_review: "needs_review",
      rejected: "rejected",
      superseded: "superseded"
    }, default: :confirmed, validate: true, scopes: false

    validates :kind, :name, presence: true

    scope :for_kind, ->(kind) { where(kind: kind) }

    # --- Drift nudge readers (phase 5) -------------------------------------
    # The drift scanner and the dismissal endpoint write `drift` /
    # `drift_silenced_at` / `drift_dismissed_amount` via update_columns ON
    # PURPOSE: these are UI bookkeeping, and a regular save would bump
    # lock_version, 409-ing an open editor drawer mid-autosave. These readers
    # therefore treat `drift` as a plain hash, never as model state.

    def drift_nudge?
      drift_status == "drifted"
    end

    def drift_source_gone?
      drift_status == "source_gone"
    end

    # BigDecimal or nil. Amounts in the drift payload are decimal STRINGS
    # ("1340.0") per the scanner contract.
    def drift_proposed_amount
      raw = (drift || {})["proposed_amount"]
      return nil if raw.blank?

      BigDecimal(raw.to_s)
    rescue ArgumentError, TypeError
      nil
    end

    private
      def drift_status
        (drift || {})["status"]
      end
  end
end
