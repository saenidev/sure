module Forecast
  class CanvasDraftsController < BaseController
    def create
      @event = @family.forecast_events.new(event_params)
      @event.behavior = "additive"
      @event.status = "planned" if @event.status.blank?
      @event.currency = @family.currency if @event.currency.blank?
      @event.probability_weight = 1.0 if @event.probability_weight.blank?

      if @event.save
        render json: {
          event: Forecast::CanvasReadModel.new(Forecast::Workspace.new(family: @family)).event_marker(@event),
          stale: true,
          message: I18n.t("forecasts.canvas.drafts.created", default: "Event saved. Regenerate the forecast to update projections.")
        }, status: :created
      else
        render json: { errors: @event.errors.to_hash(true) }, status: :unprocessable_entity
      end
    end

    def fork
      scenario =
        if params[:source_scenario_ids].present?
          fork_scenario_stack
        elsif params[:source_scenario_id].present?
          source = @family.forecast_scenarios.find(params[:source_scenario_id])
          source.duplicate_for_family!(family: @family, user: Current.user, name: params[:name])
        else
          @family.forecast_scenarios.create!(
            name: params[:name].presence || I18n.t("forecasts.canvas.forks.default_name", default: "Canvas scenario"),
            status: "active",
            approval_status: "manual",
            starts_on: params[:starts_on].presence,
            created_by_user: Current.user
          )
        end

      render json: {
        scenario: scenario_payload(scenario),
        stale: true,
        message: I18n.t("forecasts.canvas.forks.created", default: "Scenario created. Regenerate the forecast to update projections.")
      }, status: :created
    rescue ActiveRecord::RecordInvalid => e
      render json: { errors: e.record.errors.to_hash(true) }, status: :unprocessable_entity
    end

    private
      def event_params
        permitted = params.require(:forecast_event).permit(
          :name, :description, :effect_type, :amount, :currency,
          :starts_on, :ends_on, :status, :probability_weight,
          :forecast_scenario_id, :account_id, :destination_account_id, :category_id,
          :recurring, recurrence_rule: %i[frequency interval day_of_month],
          source_metadata: %i[destination_amount destination_currency]
        )

        scope_association_ids(permitted)
        normalize_recurrence(permitted)
        normalize_source_metadata(permitted)
        permitted
      end

      def scope_association_ids(permitted)
        if permitted[:forecast_scenario_id].present?
          permitted[:forecast_scenario_id] = @family.forecast_scenarios.find(permitted[:forecast_scenario_id]).id
        end
        if permitted[:account_id].present?
          permitted[:account_id] = @family.accounts.find(permitted[:account_id]).id
        end
        if permitted[:destination_account_id].present?
          permitted[:destination_account_id] = @family.accounts.find(permitted[:destination_account_id]).id
        end
        if permitted[:category_id].present?
          permitted[:category_id] = @family.categories.find(permitted[:category_id]).id
        end
      end

      def normalize_recurrence(permitted)
        recurring = ActiveModel::Type::Boolean.new.cast(permitted.delete(:recurring))
        rule = permitted[:recurrence_rule]

        unless recurring && rule.present?
          permitted[:recurrence_rule] = {}
          return
        end

        cleaned = { "frequency" => rule[:frequency].presence || "monthly" }
        cleaned["interval"] = rule[:interval].to_i if rule[:interval].present?
        if cleaned["frequency"] == "monthly" && rule[:day_of_month].present?
          cleaned["day_of_month"] = rule[:day_of_month].to_i
        end
        permitted[:recurrence_rule] = cleaned
      end

      def normalize_source_metadata(permitted)
        metadata = permitted[:source_metadata]
        return permitted[:source_metadata] = {} if metadata.blank?

        amount = metadata[:destination_amount]
        currency = metadata[:destination_currency]

        if amount.present? && currency.present?
          permitted[:source_metadata] = {
            "destination_amount" => amount,
            "destination_currency" => currency
          }
        else
          permitted[:source_metadata] = {}
        end
      end

      def fork_scenario_stack
        ids = source_scenario_ids
        raise ActiveRecord::RecordNotFound if ids.blank?

        sources = @family.forecast_scenarios.where(id: ids).ordered.to_a
        raise ActiveRecord::RecordNotFound if sources.size != ids.size

        ForecastScenario.transaction do
          scenario = @family.forecast_scenarios.create!(
            name: params[:name].presence || I18n.t("forecasts.canvas.forks.default_stack_name", default: "Canvas stack fork"),
            description: I18n.t(
              "forecasts.canvas.forks.stack_description",
              default: "Forked from %{sources}.",
              sources: sources.map(&:name).to_sentence
            ),
            status: "disabled",
            approval_status: "manual",
            starts_on: params[:starts_on].presence || sources.filter_map(&:starts_on).min,
            ends_on: sources.filter_map(&:ends_on).max,
            color: sources.first&.color,
            source_metadata: {
              "canvas_fork" => {
                "source" => "scenario_stack",
                "source_scenario_ids" => sources.map(&:id),
                "source_scenario_names" => sources.map(&:name)
              }
            },
            created_by_user: Current.user
          )

          sources.each { |source| source.copy_planning_children_into!(scenario, family: @family) }
          scenario
        end
      end

      def source_scenario_ids
        Array(params[:source_scenario_ids])
          .flat_map { |value| value.to_s.split(",") }
          .compact_blank
          .uniq
      end

      def scenario_payload(scenario)
        {
          id: scenario.id,
          name: scenario.name,
          label: scenario.name,
          status: scenario.status,
          status_label: I18n.t("forecasts.scenarios.statuses.#{scenario.status}", default: scenario.status.humanize),
          parent_scenario_id: scenario.parent_scenario_id,
          edit_url: edit_forecast_scenario_path(scenario)
        }
      end
  end
end
