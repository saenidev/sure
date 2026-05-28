module Forecast
  class LiquidityClassifier
    def initialize(family:, scenario_ids:)
      @family = family
      @scenario_ids = Array(scenario_ids).compact_blank
    end

    def call(account, on: Date.current)
      override = overrides_for(on)[account.id]
      return override if override.present?

      return "debt" if account.liability?
      return "restricted" if family.tax_advantaged_account_ids.include?(account.id)

      case account.accountable_type
      when "Depository" then "cash"
      when "Investment", "Crypto" then "liquid"
      when "Property", "Vehicle", "OtherAsset" then "illiquid"
      else "illiquid"
      end
    end

    private
      attr_reader :family, :scenario_ids

      def overrides_for(date)
        @overrides_by_date ||= {}
        @overrides_by_date[date] ||= begin
          scenario_order = scenario_ids.each_with_index.to_h
          settings = family.forecast_account_liquidity_settings
            .where(forecast_scenario_id: [ nil, *scenario_ids ])
            .includes(:forecast_scenario)
            .to_a
            .sort_by { |setting| [ setting.forecast_scenario_id ? scenario_order.fetch(setting.forecast_scenario_id, 0) + 1 : 0, setting.updated_at || Time.at(0), setting.account_id.to_s, setting.id ] }

          settings.each_with_object({}) do |setting, memo|
            next unless setting_active_on?(setting, date)

            memo[setting.account_id] = setting.liquidity_class
          end
        end
      end

      def setting_active_on?(setting, date)
        starts_on = [ setting.starts_on, setting.forecast_scenario&.starts_on ].compact.max
        ends_on = [ setting.ends_on, setting.forecast_scenario&.ends_on ].compact.min
        return false if starts_on.present? && date < starts_on
        return false if ends_on.present? && date > ends_on

        true
      end
  end
end
