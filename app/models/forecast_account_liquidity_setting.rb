class ForecastAccountLiquiditySetting < ApplicationRecord
  LIQUIDITY_CLASSES = %w[cash liquid restricted illiquid debt ignored].freeze

  belongs_to :family
  belongs_to :forecast_scenario, optional: true
  belongs_to :account

  validates :liquidity_class, presence: true, inclusion: { in: LIQUIDITY_CLASSES }
  validate :records_belong_to_family
  validate :date_range_valid
  validate :date_window_does_not_overlap

  private
    def records_belong_to_family
      if account.present? && account.family_id != family_id
        errors.add(:account, "must belong to the forecast family")
      end

      if forecast_scenario.present? && forecast_scenario.family_id != family_id
        errors.add(:forecast_scenario, "must belong to the forecast family")
      end
    end

    def date_range_valid
      return if ends_on.blank? || starts_on.blank? || ends_on >= starts_on

      errors.add(:ends_on, "must be on or after starts_on")
    end

    def date_window_does_not_overlap
      return if family_id.blank? || account_id.blank?

      scope = family.forecast_account_liquidity_settings.where(account_id: account_id)
      scope = if forecast_scenario_id.present?
        scope.where(forecast_scenario_id: forecast_scenario_id)
      else
        scope.where(forecast_scenario_id: nil)
      end
      scope = scope.where.not(id: id) if id.present?

      return unless scope.any? { |setting| windows_overlap?(starts_on, ends_on, setting.starts_on, setting.ends_on) }

      errors.add(:base, "liquidity setting overlaps another setting for this account and scenario")
    end

    def windows_overlap?(left_start, left_end, right_start, right_end)
      starts_before_other_ends = left_start.blank? || right_end.blank? || left_start <= right_end
      other_starts_before_ends = right_start.blank? || left_end.blank? || right_start <= left_end

      starts_before_other_ends && other_starts_before_ends
    end
end
