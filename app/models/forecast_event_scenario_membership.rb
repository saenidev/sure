class ForecastEventScenarioMembership < ApplicationRecord
  belongs_to :family
  belongs_to :forecast_event
  belongs_to :forecast_scenario

  before_validation :default_family

  validates :forecast_scenario_id, uniqueness: { scope: :forecast_event_id }
  validate :records_belong_to_family

  private
    def default_family
      self.family ||= forecast_event&.family || forecast_scenario&.family
    end

    def records_belong_to_family
      if forecast_event.present? && forecast_event.family_id != family_id
        errors.add(:forecast_event, "must belong to the forecast family")
      end

      if forecast_scenario.present? && forecast_scenario.family_id != family_id
        errors.add(:forecast_scenario, "must belong to the forecast family")
      end
    end
end
