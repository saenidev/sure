class ForecastEvent < ApplicationRecord
  include Monetizable

  EFFECT_TYPES = %w[
    income expense transfer debt_drawdown debt_payment debt_interest
    portfolio_contribution portfolio_withdrawal market_shock debt_terms_override
  ].freeze
  # debt_terms_override carries its refinance assumptions in source_metadata
  # (rate/payment/effective date) rather than an `amount`, so it is intentionally
  # excluded from the amount-based effect families.
  AMOUNT_EFFECT_TYPES = %w[
    income expense transfer debt_drawdown debt_payment debt_interest
    portfolio_contribution portfolio_withdrawal market_shock
  ].freeze
  DIRECTIONAL_AMOUNT_EFFECT_TYPES = AMOUNT_EFFECT_TYPES - %w[market_shock]
  BEHAVIORS = %w[additive].freeze
  STATUSES = %w[planned accepted ignored disabled].freeze

  belongs_to :family
  belongs_to :forecast_scenario, optional: true
  belongs_to :account, optional: true
  belongs_to :destination_account, class_name: "Account", optional: true
  belongs_to :category, optional: true

  has_many :forecast_event_links, dependent: :nullify

  monetize :amount, allow_nil: true

  validates :name, :effect_type, :behavior, :starts_on, :status, presence: true
  validates :effect_type, inclusion: { in: EFFECT_TYPES }
  validates :behavior, inclusion: { in: BEHAVIORS }
  validates :status, inclusion: { in: STATUSES }
  validates :amount, numericality: true, allow_nil: true
  validates :probability_weight, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 1 }
  validates :currency, presence: true, if: -> { amount.present? }
  validate :date_range_valid
  validate :associations_belong_to_family
  validate :amount_required_for_amount_effects
  validate :directional_amounts_are_positive
  validate :transfer_has_accounts
  validate :cross_currency_transfer_has_destination_amount
  validate :recurrence_rule_supported
  validate :debt_terms_override_has_refinance_metadata

  def recurring?
    recurrence_rule.present?
  end

  private
    def date_range_valid
      return if ends_on.blank? || starts_on.blank? || ends_on >= starts_on

      errors.add(:ends_on, "must be on or after starts_on")
    end

    def associations_belong_to_family
      validate_family_match(forecast_scenario, :forecast_scenario)
      validate_family_match(account, :account)
      validate_family_match(destination_account, :destination_account)
      validate_family_match(category, :category)
    end

    def validate_family_match(record, attribute)
      return if record.blank? || record.family_id == family_id

      errors.add(attribute, "must belong to the forecast family")
    end

    def amount_required_for_amount_effects
      return unless effect_type.in?(AMOUNT_EFFECT_TYPES)
      return if amount.present?

      errors.add(:amount, "must be present for amount-based forecast events")
    end

    def directional_amounts_are_positive
      return unless effect_type.in?(DIRECTIONAL_AMOUNT_EFFECT_TYPES)
      return if amount.blank? || amount.to_d.positive?

      errors.add(:amount, "must be greater than 0 for directional forecast events")
    end

    def transfer_has_accounts
      return unless effect_type == "transfer"

      errors.add(:account, "must be present for transfer events") if account.blank?
      errors.add(:destination_account, "must be present for transfer events") if destination_account.blank?
    end

    def cross_currency_transfer_has_destination_amount
      return unless effect_type == "transfer"
      return if account.blank? || destination_account.blank?
      return if account.currency == destination_account.currency

      destination_amount = source_metadata["destination_amount"]
      destination_currency = source_metadata["destination_currency"]

      if destination_amount.blank? || destination_currency.blank?
        errors.add(:source_metadata, "must include destination_amount and destination_currency for cross-currency transfer events")
        return
      end

      # Guard the JSON shape so a malformed destination amount cannot slip through
      # present? and be treated as a same-currency transfer downstream.
      unless positive_decimal?(destination_amount)
        errors.add(:source_metadata, "destination_amount must be a positive number for cross-currency transfer events")
      end
    end

    def positive_decimal?(value)
      BigDecimal(value.to_s).positive?
    rescue ArgumentError, TypeError
      false
    end

    def debt_terms_override_has_refinance_metadata
      return unless effect_type == "debt_terms_override"

      errors.add(:account, "must be present for debt_terms_override events") if account.blank?

      refinance = source_metadata["refinance"]
      unless refinance.respond_to?(:fetch)
        errors.add(:source_metadata, "must include a refinance object for debt_terms_override events")
        return
      end

      if refinance["effective_on"].blank?
        errors.add(:source_metadata, "refinance must include effective_on for debt_terms_override events")
      end

      new_rate = refinance["new_annual_rate"]
      new_payment = refinance["new_monthly_payment"]
      if new_rate.blank? && new_payment.blank?
        errors.add(:source_metadata, "refinance must include new_annual_rate or new_monthly_payment for debt_terms_override events")
      end

      if new_rate.present? && !non_negative_decimal?(new_rate)
        errors.add(:source_metadata, "refinance new_annual_rate must be a non-negative number")
      end

      if new_payment.present? && !non_negative_decimal?(new_payment)
        errors.add(:source_metadata, "refinance new_monthly_payment must be a non-negative number")
      end

      new_principal = refinance["new_principal"]
      if new_principal.present? && !non_negative_decimal?(new_principal)
        errors.add(:source_metadata, "refinance new_principal must be a non-negative number")
      end
    end

    def non_negative_decimal?(value)
      BigDecimal(value.to_s) >= 0
    rescue ArgumentError, TypeError
      false
    end

    def recurrence_rule_supported
      return if recurrence_rule.blank?
      unless recurrence_rule.respond_to?(:fetch)
        errors.add(:recurrence_rule, "must be an object")
        return
      end

      frequency = recurrence_rule.fetch("frequency", "monthly")
      errors.add(:recurrence_rule, "frequency must be weekly or monthly") unless frequency.in?(%w[weekly monthly])

      interval = recurrence_rule.fetch("interval", 1).to_i
      errors.add(:recurrence_rule, "interval must be between 1 and 60") unless interval.between?(1, 60)

      return unless frequency == "monthly"

      day_of_month = recurrence_rule.fetch("day_of_month", starts_on&.day || 1).to_i
      errors.add(:recurrence_rule, "day_of_month must be between 1 and 31") unless day_of_month.between?(1, 31)
    end
end
