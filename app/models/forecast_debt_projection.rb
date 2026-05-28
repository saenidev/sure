class ForecastDebtProjection < ApplicationRecord
  include Forecast::ImmutableOutput

  SOURCES = %w[debt_profile_snapshot account_balance_only forecast_event].freeze

  belongs_to :forecast_month
  belongs_to :account, optional: true
  belongs_to :debt_profile, optional: true

  validates :projection_key, :source, :currency, presence: true
  validates :source, inclusion: { in: SOURCES }
  validates :projection_key, uniqueness: { scope: :forecast_month_id }
  validates :cash_payment_gap, numericality: { greater_than_or_equal_to: 0 }
  validate :records_belong_to_family
  validate :source_snapshot_explains_output

  private
    def source_snapshot_explains_output
      return if source_snapshot.present?

      errors.add(:source_snapshot, "must explain the generated output")
    end

    def records_belong_to_family
      family_id = forecast_month&.forecast_run&.family_id
      return if family_id.blank?

      if account.present? && account.family_id != family_id
        errors.add(:account, "must belong to the forecast family")
      end

      if debt_profile.present? && debt_profile.account&.family_id != family_id
        errors.add(:debt_profile, "must belong to the forecast family")
      end

      if debt_profile.present? && account_id.present? && debt_profile.account_id != account_id
        errors.add(:debt_profile, "must belong to the projected account")
      end
    end
end
