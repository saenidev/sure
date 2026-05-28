class ForecastDay < ApplicationRecord
  include Forecast::ImmutableOutput

  belongs_to :forecast_run

  validates :date, :scenario_stack_key, :currency, presence: true
  validates :date, uniqueness: { scope: %i[forecast_run_id scenario_stack_key] }
end
