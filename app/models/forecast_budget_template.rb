class ForecastBudgetTemplate < ApplicationRecord
  belongs_to :family
  has_many :forecast_budget_template_amounts, dependent: :destroy

  validates :name, :currency, presence: true
  validate :family_present

  def apply_to_family!(family:, user:)
    horizon = ForecastBudgetPlan.default_horizon_for(family)
    family.forecast_budget_plans.transaction do
      scenario = family.forecast_scenarios.create!(
        name: name,
        description: description,
        status: "disabled",
        approval_status: "manual",
        starts_on: horizon.fetch(:start_on),
        ends_on: horizon.fetch(:end_on),
        source_metadata: {
          "forecast_budget_template_id" => id,
          "source" => "forecast_budget_template"
        },
        created_by_user: user
      )

      plan = family.forecast_budget_plans.create!(
        forecast_scenario: scenario,
        base_period_start_on: horizon.fetch(:start_on),
        horizon_start_on: horizon.fetch(:start_on),
        horizon_end_on: horizon.fetch(:end_on),
        currency: currency,
        source_metadata: {
          "forecast_budget_template_id" => id,
          "source" => "forecast_budget_template"
        }
      )

      forecast_budget_template_amounts.find_each do |amount|
        plan.forecast_budget_plan_amounts.create!(
          family: family,
          category: amount.category,
          period_start_on: plan.base_period_start_on,
          amount_type: amount.amount_type,
          amount: amount.amount,
          currency: amount.currency,
          note: amount.note,
          source_metadata: amount.source_metadata
        )
      end

      plan
    end
  end

  private
    def family_present
      errors.add(:family, "must be present") if family.blank?
    end
end
