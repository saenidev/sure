class ForecastMonth < ApplicationRecord
  include Forecast::ImmutableOutput

  belongs_to :forecast_run

  has_many :forecast_category_projections, dependent: :destroy
  has_many :forecast_debt_projections, dependent: :destroy

  validates :period_start_on, :period_end_on, :scenario_stack_key, :precision, :currency, presence: true
  validates :period_start_on, uniqueness: { scope: %i[forecast_run_id scenario_stack_key] }
  validate :period_ordered

  private
    def period_ordered
      return if period_start_on.blank? || period_end_on.blank? || period_end_on >= period_start_on

      errors.add(:period_end_on, "must be on or after period_start_on")
    end
end
