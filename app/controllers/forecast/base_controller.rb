module Forecast
  # Shared base for the additive `Forecast::` controller namespace. Every later
  # slice hangs off this so that all reads/writes are scoped through the current
  # family. Cross-family ids raise ActiveRecord::RecordNotFound (-> 404) because
  # lookups go through the family association rather than trusting params[:id].
  class BaseController < ApplicationController
    before_action :set_family
    before_action :set_forecast_breadcrumbs

    private
      def set_family
        @family = Current.family
      end

      def set_forecast_breadcrumbs
        collection_label = forecast_collection_breadcrumb_label
        return if collection_label.blank?

        @breadcrumbs = [
          [ t("breadcrumbs.home"), root_path ],
          [ t("forecasts.show.title"), forecast_path ]
        ]

        if forecast_collection_action?
          @breadcrumbs << [ collection_label, nil ]
        else
          @breadcrumbs << [ collection_label, forecast_collection_breadcrumb_path ]
          @breadcrumbs << [ forecast_current_breadcrumb_label, nil ]
        end
      end

      def forecast_collection_action?
        return true if action_name.in?(%w[index show])
        return true if action_name == "create" && controller_path.in?(%w[forecast/event_links forecast/templates])

        false
      end

      def forecast_collection_breadcrumb_label
        case controller_path
        when "forecast/canvas" then t("forecasts.canvas.title")
        when "forecast/scenarios" then t("forecasts.scenarios.index.title")
        when "forecast/events" then t("forecasts.events.index.title")
        when "forecast/goals" then t("forecasts.goals.index.title")
        when "forecast/account_liquidity_settings" then t("forecasts.liquidity_settings.index.title")
        when "forecast/budget_plans" then t("forecasts.budget_plans.index.title")
        when "forecast/budget_templates" then t("forecasts.budget_templates.index.title")
        when "forecast/budget_overrides" then t("forecasts.budget_overrides.index.title")
        when "forecast/event_links" then t("forecasts.reconciliation.index.title")
        when "forecast/templates" then t("forecasts.templates.index.title")
        when "forecast/sensitivity" then t("forecasts.sensitivity.heading")
        end
      end

      def forecast_collection_breadcrumb_path
        case controller_path
        when "forecast/canvas" then forecast_canvas_path
        when "forecast/scenarios" then forecast_scenarios_path
        when "forecast/events" then forecast_events_path
        when "forecast/goals" then forecast_goals_path
        when "forecast/account_liquidity_settings" then forecast_account_liquidity_settings_path
        when "forecast/budget_plans" then forecast_budget_plans_path
        when "forecast/budget_templates" then forecast_budget_plans_path
        when "forecast/budget_overrides" then forecast_budget_overrides_path
        when "forecast/event_links" then forecast_event_links_path
        when "forecast/templates" then forecast_templates_path
        when "forecast/sensitivity" then forecast_sensitivity_path
        end
      end

      def forecast_current_breadcrumb_label
        case action_name
        when "new", "create" then forecast_new_breadcrumb_label
        when "edit", "update" then forecast_edit_breadcrumb_label
        else forecast_collection_breadcrumb_label
        end
      end

      def forecast_new_breadcrumb_label
        case controller_path
        when "forecast/scenarios" then t("forecasts.scenarios.new.title")
        when "forecast/events" then t("forecasts.events.new.title")
        when "forecast/goals" then t("forecasts.goals.new.title")
        when "forecast/account_liquidity_settings" then t("forecasts.liquidity_settings.new.title")
        when "forecast/budget_plans" then t("forecasts.budget_plans.new.title")
        when "forecast/budget_overrides" then t("forecasts.budget_overrides.new.title")
        else forecast_collection_breadcrumb_label
        end
      end

      def forecast_edit_breadcrumb_label
        case controller_path
        when "forecast/scenarios" then t("forecasts.scenarios.edit.title")
        when "forecast/events" then t("forecasts.events.edit.title")
        when "forecast/goals" then t("forecasts.goals.edit.title")
        when "forecast/account_liquidity_settings" then t("forecasts.liquidity_settings.edit.title")
        when "forecast/budget_plans" then t("forecasts.budget_plans.edit.title")
        when "forecast/budget_overrides" then t("forecasts.budget_overrides.edit.title")
        else forecast_collection_breadcrumb_label
        end
      end

      # Look up a forecast run group scoped to the current family. Eager-loads
      # the runs so callers rendering a group avoid N+1 queries.
      def find_run_group_scoped(id = params[:id])
        @family.forecast_run_groups.includes(:forecast_runs).find(id)
      end

      def set_run_group
        @run_group = find_run_group_scoped
      end
  end
end
