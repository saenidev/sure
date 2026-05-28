class ForecastRunGroup < ApplicationRecord
  include Forecast::ImmutableOutput
  include Forecast::UserSnapshot

  RUN_TYPES = %w[manual weekly market_close hermes].freeze
  STATUSES = %w[pending running completed failed].freeze

  enum :status, STATUSES.index_with(&:itself), validate: false

  belongs_to :family
  belongs_to :user, optional: true
  belongs_to :supersedes_forecast_run_group, class_name: "ForecastRunGroup", optional: true

  has_many :forecast_runs, dependent: :destroy
  has_one :forecast_review, dependent: :destroy

  validates :name, :run_type, :status, :currency, :horizon_start_on, :horizon_end_on, :daily_until_on, presence: true
  validates :run_type, inclusion: { in: RUN_TYPES }
  validates :status, inclusion: { in: STATUSES }
  validate :user_belongs_to_family
  validate :superseded_group_belongs_to_family
  validate :horizon_ordered
  validate :completed_group_has_completed_runs

  private
    def user_belongs_to_family
      return if user.blank? || user.family_id == family_id

      errors.add(:user, "must belong to the forecast family")
    end

    def superseded_group_belongs_to_family
      return if supersedes_forecast_run_group.blank? || supersedes_forecast_run_group.family_id == family_id

      errors.add(:supersedes_forecast_run_group, "must belong to the forecast family")
    end

    def horizon_ordered
      return if horizon_start_on.blank? || horizon_end_on.blank? || horizon_end_on >= horizon_start_on

      errors.add(:horizon_end_on, "must be on or after horizon_start_on")
    end

    def completed_group_has_completed_runs
      return unless status == "completed"

      runs = forecast_runs.to_a
      return if runs.any? && runs.all?(&:completed?)

      errors.add(:base, "completed forecast run groups require at least one completed run")
    end
end
