class ForecastGoal < ApplicationRecord
  include Monetizable

  GOAL_TYPES = %w[
    minimum_cash_runway minimum_liquid_runway minimum_cash_balance
    maximum_debt_balance debt_payoff portfolio_balance
    monthly_savings life_event_readiness
  ].freeze
  BLOCKING_BEHAVIORS = %w[warn blocks_scenario blocks_stack].freeze
  STATUSES = %w[active disabled archived].freeze

  belongs_to :family
  belongs_to :forecast_scenario, optional: true

  monetize :target_amount, allow_nil: true

  validates :name, :goal_type, :blocking_behavior, :status, presence: true
  validates :goal_type, inclusion: { in: GOAL_TYPES }
  validates :blocking_behavior, inclusion: { in: BLOCKING_BEHAVIORS }
  validates :status, inclusion: { in: STATUSES }
  validates :currency, presence: true, if: -> { target_amount.present? }
  validates :target_amount, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
  validates :target_duration_days, numericality: { only_integer: true, greater_than: 0 }, allow_nil: true
  validate :scenario_belongs_to_family
  validate :date_range_valid
  validate :target_fields_match_goal_type

  private
    def scenario_belongs_to_family
      return if forecast_scenario.blank? || forecast_scenario.family_id == family_id

      errors.add(:forecast_scenario, "must belong to the forecast family")
    end

    def date_range_valid
      return if starts_on.blank? || ends_on.blank? || starts_on <= ends_on

      errors.add(:ends_on, "must be on or after starts_on")
    end

    def target_fields_match_goal_type
      if goal_type.in?(%w[minimum_cash_runway minimum_liquid_runway]) && target_duration_days.blank?
        errors.add(:target_duration_days, "must be present for runway goals")
      end

      if goal_type.in?(%w[minimum_cash_balance maximum_debt_balance debt_payoff portfolio_balance monthly_savings life_event_readiness]) && target_amount.blank?
        errors.add(:target_amount, "must be present for amount goals")
      end
    end
end
