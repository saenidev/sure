module Debt
  module FederalStudentLoan
    class Profile
      ROOT_KEY = "federal_student_loan"
      SUBSIDY_TYPES = %w[subsidized unsubsidized mixed].freeze
      SCHOOL_STATUSES = %w[in_school grace repayment deferment forbearance].freeze
      PLAN_CODES = %w[standard_10_year ibr rap_estimated_2026 tiered_standard_estimated_2026].freeze
      DEFAULT_PLAN_CODES = %w[standard_10_year ibr].freeze
      DECIMAL_FIELDS = %w[
        principal_balance
        accrued_interest_balance
        capitalized_interest_total
        interest_bearing_principal_balance
        weighted_average_rate
      ].freeze
      REPAYMENT_DECIMAL_FIELDS = {
        "annual_income" => "annual income",
        "poverty_guideline" => "poverty guideline"
      }.freeze
      REPAYMENT_INTEGER_FIELDS = {
        "dependent_count" => "dependent count",
        "family_size" => "family size",
        "policy_year" => "policy year"
      }.freeze

      def initialize(debt_profile)
        @debt_profile = debt_profile
      end

      def enabled?
        ActiveModel::Type::Boolean.new.cast(data["enabled"])
      end

      def enabled
        enabled?
      end

      def subsidy_type
        data["subsidy_type"]
      end

      def school_status
        data["school_status"]
      end

      def principal_balance
        decimal(data["principal_balance"])
      end

      def accrued_interest_balance
        decimal(data["accrued_interest_balance"])
      end

      def capitalized_interest_total
        decimal(data["capitalized_interest_total"])
      end

      def interest_bearing_principal_balance
        return principal_balance unless subsidy_type == "mixed"

        decimal(data["interest_bearing_principal_balance"])
      end

      def servicer_balance_as_of
        parse_date(data["servicer_balance_as_of"])
      end

      def weighted_average_rate
        decimal(data["weighted_average_rate"])
      end

      def repayment_assumptions
        data.fetch("repayment_assumptions", {})
      end

      def selected_plan_codes
        return DEFAULT_PLAN_CODES unless repayment_assumptions.key?("selected_plan_codes")

        Array(repayment_assumptions["selected_plan_codes"]).compact_blank
      end

      def input_value(key)
        data[key.to_s]
      end

      def assign(attributes)
        normalized = data.deep_dup

        attributes.to_h.each do |key, value|
          case key.to_s
          when "repayment_assumptions"
            normalized["repayment_assumptions"] = merged_repayment_assumptions(value)
          when "enabled"
            normalized["enabled"] = ActiveModel::Type::Boolean.new.cast(value)
          when *DECIMAL_FIELDS
            normalized[key.to_s] = value.presence
          else
            normalized[key.to_s] = value.presence
          end
        end

        write_data(normalized)
      end

      def increment_accrued_interest!(amount)
        assign(accrued_interest_balance: accrued_interest_balance + amount.to_d)
      end

      def apply_payment!(interest_amount:, principal_amount:)
        attributes = {
          accrued_interest_balance: [ accrued_interest_balance - interest_amount.to_d, 0.to_d ].max,
          principal_balance: [ principal_balance - principal_amount.to_d, 0.to_d ].max
        }

        if subsidy_type == "mixed"
          attributes[:interest_bearing_principal_balance] = [ interest_bearing_principal_balance - principal_amount.to_d, 0.to_d ].max
        end

        assign(attributes)
      end

      def capitalize_interest!(amount)
        amount = amount.to_d

        attributes = {
          principal_balance: principal_balance + amount,
          accrued_interest_balance: [ accrued_interest_balance - amount, 0.to_d ].max,
          capitalized_interest_total: capitalized_interest_total + amount
        }
        attributes[:interest_bearing_principal_balance] = interest_bearing_principal_balance + amount if subsidy_type == "mixed"

        assign(attributes)
      end

      def validate
        return unless enabled?

        unless debt_profile.account&.loan?
          debt_profile.errors.add(:base, "Federal student loan mode is only available for loan accounts")
          return
        end

        debt_profile.errors.add(:base, "Federal student loan subsidy type is invalid") unless SUBSIDY_TYPES.include?(subsidy_type)
        debt_profile.errors.add(:base, "Federal student loan school status is invalid") unless SCHOOL_STATUSES.include?(school_status)
        debt_profile.errors.add(:base, "Federal repayment plan selection is invalid") if (selected_plan_codes - PLAN_CODES).any?

        validate_decimal_field("principal_balance", "principal balance")
        validate_decimal_field("accrued_interest_balance", "accrued interest balance")
        validate_decimal_field("capitalized_interest_total", "capitalized interest total")
        validate_decimal_field("interest_bearing_principal_balance", "interest-bearing principal balance") if data["interest_bearing_principal_balance"].present?
        validate_decimal_field("weighted_average_rate", "weighted average rate") if data["weighted_average_rate"].present?
        debt_profile.errors.add(:base, "Federal student loan servicer balance date is invalid") if data["servicer_balance_as_of"].present? && servicer_balance_as_of.blank?
        validate_repayment_assumptions

        if subsidy_type == "mixed" && debt_profile.auto_accrual_enabled? && data["interest_bearing_principal_balance"].blank?
          debt_profile.errors.add(:base, "Federal mixed loans require interest-bearing principal for automatic accrual")
        end

        if subsidy_type == "mixed"
          interest_bearing_principal = decimal_for_comparison("interest_bearing_principal_balance")
          principal = decimal_for_comparison("principal_balance")

          if interest_bearing_principal.present? && principal.present? && interest_bearing_principal > principal
            debt_profile.errors.add(:base, "Federal student loan interest-bearing principal cannot exceed principal balance")
          end
        end
      end

      private
        attr_reader :debt_profile

        def data
          (debt_profile.extra || {}).fetch(ROOT_KEY, {})
        end

        def write_data(value)
          debt_profile.extra = (debt_profile.extra || {}).merge(ROOT_KEY => value.compact)
        end

        def decimal(value)
          return 0.to_d if value.blank?

          BigDecimal(value.to_s)
        end

        def parse_date(value)
          return nil if value.blank?

          Date.iso8601(value.to_s)
        rescue Date::Error
          nil
        end

        def validate_decimal_field(key, label)
          raw_value = data[key]
          return if raw_value.blank?

          value = BigDecimal(raw_value.to_s)
          unless value.finite?
            debt_profile.errors.add(:base, "Federal student loan #{label} must be a number")
            return
          end

          debt_profile.errors.add(:base, "Federal student loan #{label} must be nonnegative") if value.negative?
        rescue ArgumentError
          debt_profile.errors.add(:base, "Federal student loan #{label} must be a number")
        end

        def validate_repayment_assumptions
          REPAYMENT_DECIMAL_FIELDS.each do |key, label|
            validate_repayment_decimal_field(key, label)
          end

          REPAYMENT_INTEGER_FIELDS.each do |key, label|
            validate_repayment_integer_field(key, label)
          end
        end

        def merged_repayment_assumptions(value)
          return {} if value.nil?

          submitted = value.respond_to?(:to_h) ? value.to_h : {}
          normalized = submitted.deep_stringify_keys
          if normalized.key?("selected_plan_codes")
            normalized["selected_plan_codes"] = Array(normalized["selected_plan_codes"]).compact_blank
          end

          repayment_assumptions.deep_dup.merge(normalized)
        end

        def validate_repayment_decimal_field(key, label)
          raw_value = repayment_assumptions[key]
          return if raw_value.blank?

          value = BigDecimal(raw_value.to_s)
          unless value.finite?
            debt_profile.errors.add(:base, "Federal repayment #{label} must be a number")
            return
          end

          debt_profile.errors.add(:base, "Federal repayment #{label} must be nonnegative") if value.negative?
        rescue ArgumentError
          debt_profile.errors.add(:base, "Federal repayment #{label} must be a number")
        end

        def validate_repayment_integer_field(key, label)
          raw_value = repayment_assumptions[key]
          return if raw_value.blank?

          value = Integer(raw_value.to_s, exception: false)
          if value.nil?
            debt_profile.errors.add(:base, "Federal repayment #{label} must be a whole number")
          elsif value.negative?
            debt_profile.errors.add(:base, "Federal repayment #{label} must be nonnegative")
          end
        end

        def decimal_for_comparison(key)
          raw_value = data[key]
          return nil if raw_value.blank?

          BigDecimal(raw_value.to_s)
        rescue ArgumentError
          nil
        end
    end
  end
end
