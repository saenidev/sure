# frozen_string_literal: true

module Forecasts
  module Assumptions
    # Forecast V2 typed form object for the `living_expense` assumption kind.
    #
    # Per spec, living_expense is backend-derived in the MVP and has no
    # interactive editor yet, but the bootstrap/derivation path may save and
    # validate it, so the form exists with the full Assumption Params Contract:
    # amount, currency, frequency, category_ids, inflation_policy,
    # actualization_policy, start_anchor, end_anchor (plus an inflation_rate
    # required only for rate-based inflation policies).
    #
    # Same responsibilities and contract as SalaryForm: coercion, field-level +
    # cross-field validation, family-scoped category/milestone permission checks,
    # stale optimistic-lock detection, stable error codes, a typed params value
    # object, and normalized assumption attributes. It never persists.
    class LivingExpenseForm < BaseForm
      self.assumption_kind = "living_expense"

      FREQUENCIES = %w[annual monthly biweekly weekly].freeze
      INFLATION_POLICIES = %w[flat fixed_rate].freeze
      RATE_BASED_INFLATION_POLICIES = %w[fixed_rate].freeze
      ACTUALIZATION_POLICIES = %w[replace offset none].freeze

      attr_reader :name, :amount, :currency, :frequency, :category_ids,
                  :inflation_policy, :inflation_rate, :actualization_policy,
                  :starts_on, :ends_on, :starts_at_milestone_id,
                  :ends_at_milestone_id

      validate :validate_required_fields
      validate :validate_amount
      validate :validate_inflation_rate
      validate :validate_enums
      validate :validate_currency_field
      validate :validate_dates
      validate :validate_date_ordering
      validate :validate_references
      validate :validate_lock_version

      def params_object
        LivingExpenseParams.new(
          amount: amount_decimal,
          currency: currency,
          frequency: frequency,
          category_ids: category_ids,
          inflation_policy: inflation_policy,
          inflation_rate: rate_based_inflation? ? inflation_rate_decimal : nil,
          actualization_policy: actualization_policy,
          start_anchor: anchor_for(date: starts_on, milestone_id: starts_at_milestone_id),
          end_anchor: anchor_for(date: ends_on, milestone_id: ends_at_milestone_id)
        )
      end

      def assumption_attributes
        {
          kind: self.class.assumption_kind,
          name: name,
          currency: currency,
          amount: amount_decimal,
          starts_on: starts_at_milestone_id.present? ? nil : starts_on_date,
          ends_on: ends_at_milestone_id.present? ? nil : ends_on_date,
          starts_at_milestone_id: starts_at_milestone_id,
          ends_at_milestone_id: ends_at_milestone_id,
          params: params_object.to_h
        }
      end

      private
        def coerce_attributes
          @name = string_value(:name)
          @amount = decimal_value(:amount)
          @currency = string_value(:currency)
          @frequency = string_value(:frequency)
          @category_ids = coerce_category_ids
          @inflation_policy = string_value(:inflation_policy)
          @inflation_rate = decimal_value(:inflation_rate)
          @actualization_policy = string_value(:actualization_policy)
          @starts_on = date_value(:starts_on)
          @ends_on = date_value(:ends_on)
          @starts_at_milestone_id = string_value(:starts_at_milestone_id)
          @ends_at_milestone_id = string_value(:ends_at_milestone_id)
        end

        def coerce_category_ids
          raw = input["category_ids"]
          return [] if raw.nil?

          Array(raw).map { |id| id.to_s.strip }.reject(&:empty?)
        end

        # --- field-level validations ------------------------------------------

        def validate_required_fields
          add_error(:name, "blank") if name.blank?
          add_error(:amount, "blank") if input["amount"].to_s.strip.empty?
          add_error(:currency, "blank") if currency.blank?
          add_error(:frequency, "blank") if frequency.blank?
          add_error(:inflation_policy, "blank") if inflation_policy.blank?
          add_error(:actualization_policy, "blank") if actualization_policy.blank?
        end

        def validate_amount
          return if amount.nil?

          if amount == :invalid
            add_error(:amount, "not_a_number")
          elsif amount <= 0
            add_error(:amount, "not_positive")
          end
        end

        def validate_inflation_rate
          if inflation_rate == :invalid
            add_error(:inflation_rate, "not_a_number")
            return
          end

          return unless rate_based_inflation?

          if inflation_rate.nil?
            add_error(:inflation_rate, "blank")
          elsif inflation_rate.negative?
            add_error(:inflation_rate, "not_positive")
          end
        end

        def validate_enums
          add_error(:frequency, "inclusion") if frequency.present? && FREQUENCIES.exclude?(frequency)
          add_error(:inflation_policy, "inclusion") if inflation_policy.present? && INFLATION_POLICIES.exclude?(inflation_policy)
          add_error(:actualization_policy, "inclusion") if actualization_policy.present? && ACTUALIZATION_POLICIES.exclude?(actualization_policy)
        end

        def validate_currency_field
          validate_currency(:currency, currency)
        end

        def validate_dates
          add_error(:starts_on, "invalid_date") if starts_on == :invalid
          add_error(:ends_on, "invalid_date") if ends_on == :invalid
        end

        # --- cross-field validations ------------------------------------------

        def validate_date_ordering
          return unless starts_on_date && ends_on_date

          add_error(:ends_on, "end_before_start") if ends_on_date < starts_on_date
        end

        # --- reference + permission checks ------------------------------------

        def validate_references
          category_ids.each do |category_id|
            validate_category_reference(:category_ids, category_id)
          end
          validate_milestone_reference(:starts_at_milestone_id, starts_at_milestone_id)
          validate_milestone_reference(:ends_at_milestone_id, ends_at_milestone_id)
        end

        # --- typed accessors ---------------------------------------------------

        def amount_decimal
          amount.is_a?(BigDecimal) ? amount : nil
        end

        def inflation_rate_decimal
          inflation_rate.is_a?(BigDecimal) ? inflation_rate : nil
        end

        def starts_on_date
          starts_on.is_a?(Date) ? starts_on : nil
        end

        def ends_on_date
          ends_on.is_a?(Date) ? ends_on : nil
        end

        def rate_based_inflation?
          RATE_BASED_INFLATION_POLICIES.include?(inflation_policy)
        end
    end
  end
end
