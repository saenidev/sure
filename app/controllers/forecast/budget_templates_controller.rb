module Forecast
  class BudgetTemplatesController < BaseController
    before_action :set_template, only: %i[apply duplicate destroy]

    def index
      redirect_to forecast_budget_plans_path
    end

    def apply
      plan = @template.apply_to_family!(family: @family, user: Current.user)
      redirect_to edit_forecast_budget_plan_path(plan), notice: t(".success", name: @template.name)
    rescue ActiveRecord::RecordInvalid => e
      redirect_to forecast_budget_plans_path, alert: t(".error", message: e.record.errors.full_messages.to_sentence)
    end

    def duplicate
      copy = @template.duplicate_for_family!(family: @family)
      redirect_to forecast_budget_plans_path, notice: t(".success", name: copy.name)
    rescue ActiveRecord::RecordInvalid => e
      redirect_to forecast_budget_plans_path, alert: t(".error", message: e.record.errors.full_messages.to_sentence)
    end

    def destroy
      @template.destroy
      redirect_to forecast_budget_plans_path, notice: t(".success")
    end

    private
      def set_template
        @template = @family.forecast_budget_templates.find(params[:id])
      end
  end
end
