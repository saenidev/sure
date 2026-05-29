class ForecastReview < ApplicationRecord
  include Forecast::UserSnapshot

  SOURCES = %w[manual weekly market_close hermes].freeze
  STATUSES = %w[draft awaiting_approval approved rejected applied superseded].freeze

  belongs_to :forecast_run_group
  belongs_to :family
  belongs_to :user, optional: true

  validates :source, :status, presence: true
  validates :source, inclusion: { in: SOURCES }
  validates :status, inclusion: { in: STATUSES }
  validates :forecast_run_group_id, uniqueness: true
  validate :records_belong_to_family
  validate :run_group_is_immutable, on: :update

  private
    def run_group_is_immutable
      return unless will_save_change_to_forecast_run_group_id?

      errors.add(:forecast_run_group_id, "cannot be changed after the review is created")
    end

    def records_belong_to_family
      if forecast_run_group.present? && forecast_run_group.family_id != family_id
        errors.add(:forecast_run_group, "must belong to the forecast family")
      end

      if user.present? && user.family_id != family_id
        errors.add(:user, "must belong to the forecast family")
      end
    end
end
