class ForecastBudgetPlan < ApplicationRecord
  belongs_to :family
  belongs_to :forecast_scenario
  has_many :forecast_budget_plan_amounts, dependent: :destroy

  before_validation :canonicalize_month_dates

  validates :base_period_start_on, :horizon_start_on, :horizon_end_on, :currency, presence: true
  validates :forecast_scenario_id, uniqueness: { message: "already has a forecast budget plan" }
  validate :scenario_belongs_to_family
  validate :date_range_valid

  class << self
    def default_horizon_for(family, start_on: Date.current)
      months = Forecast::PeriodBuilder.new(family: family, start_on: start_on).call.months
      horizon_start = family.current_custom_month_period.start_date + 1.month
      horizon_end = months.last.end_date

      { start_on: horizon_start, end_on: horizon_end }
    end
  end

  def name
    forecast_scenario&.name
  end

  def description
    forecast_scenario&.description
  end

  def active_for_period?(period)
    return false unless forecast_scenario&.active?
    return false if horizon_start_on.present? && period.start_date < horizon_start_on
    return false if horizon_end_on.present? && period.end_date > horizon_end_on
    return false if forecast_scenario.starts_on.present? && period.start_date < forecast_scenario.starts_on
    return false if forecast_scenario.ends_on.present? && period.end_date > forecast_scenario.ends_on

    true
  end

  def effective_amounts_for(period_start_on)
    canonical_period = family.custom_month_start_for(period_start_on)

    forecast_budget_plan_amounts
      .includes(:category)
      .where("period_start_on <= ?", canonical_period)
      .order(:period_start_on, :updated_at, :id)
      .each_with_object({}) do |amount, memo|
        memo[amount.amount_key] = amount
      end
  end

  def copy_into!(scenario:, family:)
    copy = family.forecast_budget_plans.create!(
      forecast_scenario: scenario,
      base_period_start_on: base_period_start_on,
      horizon_start_on: horizon_start_on,
      horizon_end_on: horizon_end_on,
      currency: currency,
      activation_metadata: activation_metadata,
      dependency_metadata: dependency_metadata,
      source_metadata: source_metadata
    )

    forecast_budget_plan_amounts.find_each do |amount|
      copy.forecast_budget_plan_amounts.create!(
        family: family,
        category: amount.category,
        period_start_on: amount.period_start_on,
        amount_type: amount.amount_type,
        amount: amount.amount,
        currency: amount.currency,
        note: amount.note,
        source_metadata: amount.source_metadata
      )
    end

    copy
  end

  private
    def canonicalize_month_dates
      return if family.blank?

      self.base_period_start_on = family.custom_month_start_for(base_period_start_on) if base_period_start_on.present?
      self.horizon_start_on = family.custom_month_start_for(horizon_start_on) if horizon_start_on.present?
      self.horizon_end_on = family.custom_month_end_for(horizon_end_on) if horizon_end_on.present?
    end

    def scenario_belongs_to_family
      return if forecast_scenario.blank? || forecast_scenario.family_id == family_id

      errors.add(:forecast_scenario, "must belong to the forecast family")
    end

    def date_range_valid
      return if horizon_start_on.blank? || horizon_end_on.blank?
      return if horizon_end_on >= horizon_start_on

      errors.add(:horizon_end_on, "must be on or after horizon start")
    end
end
