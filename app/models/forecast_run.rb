class ForecastRun < ApplicationRecord
  include Forecast::ImmutableOutput
  include Forecast::UserSnapshot

  STATUSES = %w[pending running completed failed].freeze
  FEASIBILITY_STATUSES = %w[unknown pass warn blocked].freeze

  enum :status, STATUSES.index_with(&:itself), validate: false

  belongs_to :forecast_run_group
  belongs_to :family
  belongs_to :user, optional: true

  has_many :forecast_days, dependent: :destroy
  has_many :forecast_months, dependent: :destroy
  has_many :forecast_goal_evaluations, dependent: :destroy

  validates :scenario_stack_key, :scenario_stack_snapshot, :status, :feasibility_status, :currency, presence: true
  validates :status, inclusion: { in: STATUSES }
  validates :feasibility_status, inclusion: { in: FEASIBILITY_STATUSES }
  validate :records_belong_to_family
  validate :completed_run_has_input_snapshot

  private
    def records_belong_to_family
      errors.add(:forecast_run_group, "must belong to the forecast family") if forecast_run_group.present? && forecast_run_group.family_id != family_id
      errors.add(:user, "must belong to the forecast family") if user.present? && user.family_id != family_id
    end

    def completed_run_has_input_snapshot
      return unless status == "completed"
      required_keys = %w[
        scenario_stack currency source_data_versions portfolio accounts budget_income
        budget_categories recurring_items pending_entries forecast_events debt_rows goals
        account_count budget_period_count recurring_item_count pending_entry_count
        forecast_event_count goal_count
      ]
      return if input_snapshot.present? && required_keys.all? { |key| input_snapshot.key?(key) }

      errors.add(:input_snapshot, "must include runner source sections")
    end
end
