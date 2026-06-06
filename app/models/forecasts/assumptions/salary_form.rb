# frozen_string_literal: true

module Forecasts
  module Assumptions
    # Forecast V2 typed form object for the `salary` assumption kind — the only
    # interactive assumption editor in the MVP (spec "Form Objects",
    # "Assumption Params Contracts").
    #
    # Required params per the contract: person_key, amount, gross_or_net,
    # currency, frequency, growth_policy, start_anchor, end_anchor. The form adds
    # an optional cash_account_id (the account the pay lands in) and a growth_rate
    # required only when growth_policy is rate-based.
    #
    # Responsibilities: coerce raw input, validate field-level + cross-field
    # rules, check family-scoped account/milestone references, detect stale
    # optimistic-lock conflicts, and emit stable error codes. On success it
    # returns a SalaryParams value object (#params_object) and the normalized
    # top-level assumption attributes (#assumption_attributes). It never persists.
    class SalaryForm < BaseForm
      self.assumption_kind = "salary"

      GROSS_OR_NET = %w[gross net].freeze
      FREQUENCIES = %w[annual monthly biweekly weekly].freeze
      GROWTH_POLICIES = %w[flat fixed_rate].freeze
      RATE_BASED_GROWTH_POLICIES = %w[fixed_rate].freeze

      attr_reader :name, :amount, :currency, :person_key, :gross_or_net,
                  :frequency, :growth_policy, :growth_rate, :cash_account_id,
                  :starts_on, :ends_on, :starts_at_milestone_id,
                  :ends_at_milestone_id

      validate :validate_required_fields
      validate :validate_amount
      validate :validate_growth_rate
      validate :validate_enums
      validate :validate_currency_field
      validate :validate_dates
      validate :validate_date_ordering
      validate :validate_references
      validate :validate_lock_version

      # Typed params value object. Only call after #valid? returns true.
      def params_object
        SalaryParams.new(
          person_key: person_key,
          amount: amount_decimal,
          gross_or_net: gross_or_net,
          currency: currency,
          frequency: frequency,
          growth_policy: growth_policy,
          growth_rate: rate_based_growth? ? growth_rate_decimal : nil,
          cash_account_id: cash_account_id,
          start_anchor: anchor_for(date: starts_on, milestone_id: starts_at_milestone_id),
          end_anchor: anchor_for(date: ends_on, milestone_id: ends_at_milestone_id)
        )
      end

      # Normalized top-level assumption attributes plus the serialized params.
      # Controllers/services merge these onto a new or existing record. Either a
      # fixed date OR a milestone ref is set per side, never both.
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
          @person_key = string_value(:person_key)
          @gross_or_net = string_value(:gross_or_net)
          @frequency = string_value(:frequency)
          @growth_policy = string_value(:growth_policy)
          @growth_rate = decimal_value(:growth_rate)
          @cash_account_id = string_value(:cash_account_id)
          @starts_on = date_value(:starts_on)
          @ends_on = date_value(:ends_on)
          @starts_at_milestone_id = string_value(:starts_at_milestone_id)
          @ends_at_milestone_id = string_value(:ends_at_milestone_id)
        end

        # --- field-level validations ------------------------------------------

        def validate_required_fields
          add_error(:name, "blank") if name.blank?
          add_error(:person_key, "blank") if person_key.blank?
          add_error(:amount, "blank") if input["amount"].to_s.strip.empty?
          add_error(:currency, "blank") if currency.blank?
          add_error(:gross_or_net, "blank") if gross_or_net.blank?
          add_error(:frequency, "blank") if frequency.blank?
          add_error(:growth_policy, "blank") if growth_policy.blank?
        end

        def validate_amount
          return if amount.nil? # blank handled by required check

          if amount == :invalid
            add_error(:amount, "not_a_number")
          elsif amount <= 0
            add_error(:amount, "not_positive")
          end
        end

        # growth_rate is required only for rate-based growth policies.
        def validate_growth_rate
          if growth_rate == :invalid
            add_error(:growth_rate, "not_a_number")
            return
          end

          return unless rate_based_growth?

          if growth_rate.nil?
            add_error(:growth_rate, "blank")
          elsif growth_rate.negative?
            add_error(:growth_rate, "not_positive")
          end
        end

        def validate_enums
          add_error(:gross_or_net, "inclusion") if gross_or_net.present? && GROSS_OR_NET.exclude?(gross_or_net)
          add_error(:frequency, "inclusion") if frequency.present? && FREQUENCIES.exclude?(frequency)
          add_error(:growth_policy, "inclusion") if growth_policy.present? && GROWTH_POLICIES.exclude?(growth_policy)
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
          validate_account_reference(:cash_account_id, cash_account_id)
          validate_milestone_reference(:starts_at_milestone_id, starts_at_milestone_id)
          validate_milestone_reference(:ends_at_milestone_id, ends_at_milestone_id)
        end

        # --- typed accessors ---------------------------------------------------

        def amount_decimal
          amount.is_a?(BigDecimal) ? amount : nil
        end

        def growth_rate_decimal
          growth_rate.is_a?(BigDecimal) ? growth_rate : nil
        end

        def starts_on_date
          starts_on.is_a?(Date) ? starts_on : nil
        end

        def ends_on_date
          ends_on.is_a?(Date) ? ends_on : nil
        end

        def rate_based_growth?
          RATE_BASED_GROWTH_POLICIES.include?(growth_policy)
        end
    end
  end
end
