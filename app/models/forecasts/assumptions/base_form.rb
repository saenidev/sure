# frozen_string_literal: true

module Forecasts
  module Assumptions
    # Shared behavior for Forecast V2 typed assumption form objects (spec
    # "Form Objects", "Form object rules"). Concrete forms (SalaryForm,
    # LivingExpenseForm, ...) inherit coercion helpers, family-scoped reference
    # checks, anchor normalization, optimistic-lock conflict detection, and the
    # stable-error-code interface.
    #
    # Forms own input coercion + field-level + cross-field validation + account
    # /category permission checks (all scoped to the family passed in, which is
    # always Current.family at the call site). They return a typed params value
    # object plus normalized top-level assumption attributes. They DO NOT persist:
    # controllers/services own transactions, version increments, and recompute.
    #
    # Errors are stable codes (e.g. "blank", "not_a_number", "not_positive",
    # "unknown_currency", "inclusion", "invalid_reference", "not_permitted",
    # "end_before_start", "stale_version"). The UI maps codes to localized field
    # and summary copy under config/locales `forecasts_v2.assumptions.errors.*`
    # (field labels under `forecasts_v2.assumptions.fields.*`).
    class BaseForm
      include ActiveModel::Validations

      # Subclasses set the assumption kind, e.g. "salary".
      class_attribute :assumption_kind, instance_writer: false

      attr_reader :family, :plan, :input, :assumption

      # `params` is the raw user input hash (string or symbol keys). `assumption`
      # is the existing record being edited (nil for create). `family` and `plan`
      # are already proven to belong to Current.family by the caller.
      def initialize(family:, plan:, params:, assumption: nil)
        @family = family
        @plan = plan
        @input = (params || {}).to_h.deep_stringify_keys
        @assumption = assumption
      end

      # Run coercion (memoized), then ActiveModel validations + cross-field +
      # reference/permission checks. Returns true only when there are no errors.
      def valid?
        coerce
        super
      end

      # Stable error codes recorded for a given attribute (e.g. :amount, :base).
      def error_codes_for(attribute)
        errors.where(attribute).map { |error| error.options[:code] || error.type.to_s }
      end

      private
        # Subclasses override to populate coerced attributes from `input`.
        def coerce
          return if @coerced

          @coerced = true
          coerce_attributes
        end

        def coerce_attributes
          raise NotImplementedError, "#{self.class} must implement #coerce_attributes"
        end

        # --- coercion helpers --------------------------------------------------

        def string_value(key)
          value = input[key.to_s]
          return nil if value.nil?

          stripped = value.to_s.strip
          stripped.empty? ? nil : stripped
        end

        # Coerces to BigDecimal. Returns :invalid when the raw value is present
        # but non-numeric so the caller can emit a not_a_number error.
        def decimal_value(key)
          raw = input[key.to_s]
          return nil if raw.nil? || raw.to_s.strip.empty?

          BigDecimal(raw.to_s.strip)
        rescue ArgumentError, TypeError
          :invalid
        end

        def date_value(key)
          raw = string_value(key)
          return nil if raw.nil?

          Date.iso8601(raw)
        rescue ArgumentError, TypeError
          :invalid
        end

        def integer_value(key)
          raw = input[key.to_s]
          return nil if raw.nil? || raw.to_s.strip.empty?

          Integer(raw.to_s.strip)
        rescue ArgumentError, TypeError
          :invalid
        end

        # --- shared validation helpers ----------------------------------------

        def add_error(attribute, code)
          errors.add(attribute, code, code: code)
        end

        def validate_currency(attribute, value)
          return if value.nil?

          Money::Currency.new(value)
        rescue Money::Currency::UnknownCurrencyError, ArgumentError
          add_error(attribute, "unknown_currency")
        end

        # Validates a referenced account belongs to the family. Returns the id
        # when valid/blank, records "not_permitted" otherwise.
        def validate_account_reference(attribute, account_id)
          return if account_id.nil?

          unless family.accounts.exists?(id: account_id)
            add_error(attribute, "not_permitted")
          end
        end

        # Validates a referenced category belongs to the family.
        def validate_category_reference(attribute, category_id)
          return if category_id.nil?

          unless family.categories.exists?(id: category_id)
            add_error(attribute, "not_permitted")
          end
        end

        # Validates a referenced milestone belongs to this plan. A milestone from
        # another plan/family or a nonexistent id records "invalid_reference".
        def validate_milestone_reference(attribute, milestone_id)
          return if milestone_id.nil?

          unless plan.forecast_milestones.exists?(id: milestone_id)
            add_error(attribute, "invalid_reference")
          end
        end

        # Optimistic-lock conflict detection (spec "Form object rules":
        # "stale lock/version conflicts"). When editing an existing assumption,
        # the submitted `expected_lock_version` must match the persisted value.
        def validate_lock_version
          return if assumption.nil?

          expected = integer_value(:expected_lock_version)
          return if expected.nil? # caller did not assert a version
          return if expected == :invalid # ignore; not a version assertion

          if expected != assumption.lock_version
            add_error(:base, "stale_version")
          end
        end

        # Normalizes a fixed-date / milestone anchor pair into the persisted
        # {type:, ...} shape stored in params. Date is a Date; milestone is an id.
        def anchor_for(date:, milestone_id:)
          if milestone_id.present?
            { "type" => "milestone", "milestone_id" => milestone_id }
          elsif date.is_a?(Date)
            { "type" => "fixed_date", "date" => date.iso8601 }
          end
        end
    end
  end
end
