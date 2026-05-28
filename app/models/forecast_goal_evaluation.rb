class ForecastGoalEvaluation < ApplicationRecord
  include Forecast::ImmutableOutput

  STATUSES = %w[pass warn fail blocking].freeze

  belongs_to :forecast_run
  belongs_to :forecast_goal, optional: true

  validates :goal_key, :scenario_stack_key, :status, presence: true
  validates :status, inclusion: { in: STATUSES }
  validates :goal_key, uniqueness: { scope: %i[forecast_run_id scenario_stack_key] }
  validate :goal_belongs_to_family
  validate :goal_snapshot_explains_output

  private
    def goal_snapshot_explains_output
      return if goal_snapshot.present?

      errors.add(:goal_snapshot, "must explain the generated output")
    end

    def goal_belongs_to_family
      return if forecast_goal.blank? || forecast_run.blank? || forecast_goal.family_id == forecast_run.family_id

      errors.add(:forecast_goal, "must belong to the forecast family")
    end
end
