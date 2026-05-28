module Forecast
  module ImmutableOutput
    extend ActiveSupport::Concern

    included do
      before_create :prevent_completed_forecast_append
      before_update :prevent_completed_forecast_mutation
      before_destroy :prevent_completed_forecast_mutation
    end

    private
      def prevent_completed_forecast_append
        return unless completed_forecast_parent?

        errors.add(:base, "completed forecast output is immutable")
        throw(:abort)
      end

      def prevent_completed_forecast_mutation
        return unless completed_forecast_output?

        errors.add(:base, "completed forecast output is immutable")
        throw(:abort)
      end

      def completed_forecast_parent?
        if is_a?(ForecastRun)
          forecast_run_group&.completed?
        elsif respond_to?(:forecast_run)
          forecast_run&.completed?
        elsif respond_to?(:forecast_month)
          forecast_month&.forecast_run&.completed?
        else
          false
        end
      end

      def completed_forecast_output?
        if is_a?(ForecastRunGroup) || is_a?(ForecastRun)
          status_in_database == "completed"
        elsif respond_to?(:forecast_run_id)
          completed_forecast_run_id?(attribute_in_database("forecast_run_id")) || forecast_run&.completed?
        elsif respond_to?(:forecast_month_id)
          completed_forecast_month_id?(attribute_in_database("forecast_month_id")) || forecast_month&.forecast_run&.completed?
        else
          false
        end
      end

      def completed_forecast_run_id?(run_id)
        run_id.present? && ForecastRun.where(id: run_id, status: "completed").exists?
      end

      def completed_forecast_month_id?(month_id)
        month_id.present? && ForecastMonth.joins(:forecast_run).where(id: month_id, forecast_runs: { status: "completed" }).exists?
      end
  end
end
