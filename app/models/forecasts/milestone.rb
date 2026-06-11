# frozen_string_literal: true

# Forecast V2 semantic anchor (retirement, home purchase, etc.) that assumptions
# can reference for relative date binding. Family-scoped through its plan.
module Forecasts
  class Milestone < ApplicationRecord
    self.table_name = "forecast_milestones"

    belongs_to :forecast_plan,
      class_name: "Forecasts::Plan",
      inverse_of: :forecast_milestones

    has_many :starting_assumptions,
      class_name: "Forecasts::Assumption",
      foreign_key: :starts_at_milestone_id,
      inverse_of: :starts_at_milestone,
      dependent: :nullify
    has_many :ending_assumptions,
      class_name: "Forecasts::Assumption",
      foreign_key: :ends_at_milestone_id,
      inverse_of: :ends_at_milestone,
      dependent: :nullify

    enum :kind, {
      retirement: "retirement",
      spouse_retirement: "spouse_retirement",
      child_leaves_home: "child_leaves_home",
      home_purchase: "home_purchase",
      move: "move",
      debt_payoff: "debt_payoff",
      custom: "custom"
    }, validate: true, scopes: false

    validates :name, presence: true

    scope :ordered, -> { order(:date, :created_at) }
  end
end
