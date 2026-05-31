module Forecast
  class BudgetPlansController < BaseController
    before_action :set_plan, only: %i[edit update destroy duplicate create_template]
    before_action :set_period, only: %i[edit update create_template]

    def index
      @plans = @family.forecast_budget_plans
        .includes(:forecast_scenario, :forecast_budget_plan_amounts)
        .sort_by { |plan| [ plan.forecast_scenario.position, plan.forecast_scenario.name.to_s.downcase, plan.created_at || Time.zone.at(0) ] }
      @templates = @family.forecast_budget_templates
        .includes(:forecast_budget_template_amounts)
        .order(:name, :created_at)
    end

    def new
      @defaults = default_plan_attributes
      load_dependency_options
    end

    def create
      attrs = normalized_plan_params
      horizon = default_horizon

      @plan = nil
      @family.forecast_budget_plans.transaction do
        scenario = @family.forecast_scenarios.create!(
          name: attrs[:name],
          description: attrs[:description],
          status: allowed_status(attrs[:status]),
          approval_status: "manual",
          starts_on: attrs[:starts_on].presence || horizon.fetch(:start_on),
          ends_on: attrs[:ends_on].presence || horizon.fetch(:end_on),
          created_by_user: Current.user
        )

        @plan = @family.forecast_budget_plans.create!(
          forecast_scenario: scenario,
          base_period_start_on: attrs[:base_period_start_on].presence || horizon.fetch(:start_on),
          horizon_start_on: attrs[:horizon_start_on].presence || horizon.fetch(:start_on),
          horizon_end_on: attrs[:horizon_end_on].presence || horizon.fetch(:end_on),
          currency: @family.currency,
          activation_metadata: activation_metadata_from(attrs),
          dependency_metadata: dependency_metadata_from(attrs)
        )
      end

      redirect_to edit_forecast_budget_plan_path(@plan), notice: t(".success")
    rescue ActiveRecord::RecordInvalid => e
      @defaults = default_plan_attributes.merge(attrs || {})
      @errors = e.record.errors.full_messages
      load_dependency_options
      render :new, status: :unprocessable_entity
    end

    def edit
      load_builder_context
    end

    def update
      attrs = normalized_plan_params

      @plan.transaction do
        @plan.forecast_scenario.update!(
          name: attrs[:name],
          description: attrs[:description],
          status: allowed_status(attrs[:status]),
          starts_on: attrs[:starts_on],
          ends_on: attrs[:ends_on]
        )
        @plan.update!(
          base_period_start_on: attrs[:base_period_start_on],
          horizon_start_on: attrs[:horizon_start_on],
          horizon_end_on: attrs[:horizon_end_on],
          currency: @family.currency,
          activation_metadata: activation_metadata_from(attrs),
          dependency_metadata: dependency_metadata_from(attrs)
        )
        apply_amount_rows!(attrs[:amounts] || {})
      end

      redirect_to edit_forecast_budget_plan_path(@plan, period: Budget.date_to_param(@period_start_on)), notice: t(".success")
    rescue ActiveRecord::RecordInvalid => e
      @errors = e.record.errors.full_messages
      load_builder_context
      render :edit, status: :unprocessable_entity
    end

    def destroy
      @plan.destroy
      redirect_to forecast_budget_plans_path, notice: t(".success")
    end

    def duplicate
      copy = @plan.forecast_scenario.duplicate_for_family!(family: @family, user: Current.user)
      redirect_to edit_forecast_budget_plan_path(copy.forecast_budget_plan), notice: t(".success")
    rescue ActiveRecord::RecordInvalid => e
      redirect_to forecast_budget_plans_path, alert: t(".error", message: e.record.errors.full_messages.to_sentence)
    end

    def create_template
      template = build_template_from_plan!
      redirect_to forecast_budget_plans_path, notice: t(".success", name: template.name)
    rescue ActiveRecord::RecordInvalid => e
      redirect_to edit_forecast_budget_plan_path(@plan, period: Budget.date_to_param(@period_start_on)), alert: t(".error", message: e.record.errors.full_messages.to_sentence)
    end

    private
      def set_plan
        @plan = @family.forecast_budget_plans
          .includes(:forecast_scenario)
          .find(params[:id])
      end

      def set_period
        fallback = @plan&.base_period_start_on || default_horizon.fetch(:start_on)
        @period_start_on = period_from_param(params[:period], fallback: fallback)
        @period_end_on = @family.custom_month_end_for(@period_start_on)
      end

      def load_builder_context
        @rows = amount_rows
        @budget_plan_summary = budget_plan_summary(@rows)
        load_dependency_options
      end

      def default_plan_attributes
        horizon = default_horizon
        {
          name: "",
          description: "",
          status: "active",
          starts_on: horizon.fetch(:start_on),
          ends_on: horizon.fetch(:end_on),
          base_period_start_on: horizon.fetch(:start_on),
          horizon_start_on: horizon.fetch(:start_on),
          horizon_end_on: horizon.fetch(:end_on),
          activation_trigger: "",
          activation_conditions: "",
          depends_on_scenario_ids: [],
          depends_on_goal_ids: [],
          depended_on_by_scenario_ids: [],
          depended_on_by_goal_ids: []
        }
      end

      def default_horizon
        @default_horizon ||= ForecastBudgetPlan.default_horizon_for(@family)
      end

      def normalized_plan_params
        raw = params.require(:forecast_budget_plan).permit(
          :name,
          :description,
          :status,
          :starts_on,
          :ends_on,
          :base_period_start_on,
          :horizon_start_on,
          :horizon_end_on,
          :activation_trigger,
          :activation_conditions,
          :dependency_notes,
          depends_on_scenario_ids: [],
          depends_on_goal_ids: [],
          depended_on_by_scenario_ids: [],
          depended_on_by_goal_ids: [],
          amounts: {}
        )

        raw.to_h.symbolize_keys.tap do |attrs|
          attrs[:starts_on] = parse_date(attrs[:starts_on])
          attrs[:ends_on] = parse_date(attrs[:ends_on])
          attrs[:base_period_start_on] = parse_date(attrs[:base_period_start_on])
          attrs[:horizon_start_on] = parse_date(attrs[:horizon_start_on])
          attrs[:horizon_end_on] = parse_date(attrs[:horizon_end_on])
          attrs[:name] = attrs[:name].presence || t("forecasts.budget_plans.defaults.name")
          attrs[:amounts] = attrs[:amounts].to_h
        end
      end

      def parse_date(value)
        return if value.blank?

        Date.iso8601(value.to_s)
      rescue ArgumentError
        nil
      end

      def period_from_param(param, fallback:)
        base = if param.present?
          begin
            Budget.param_to_date(param, family: @family)
          rescue ArgumentError
            fallback
          end
        else
          fallback
        end

        @family.custom_month_start_for(base)
      end

      def allowed_status(status)
        ForecastScenario::STATUSES.include?(status) ? status : "active"
      end

      def activation_metadata_from(attrs)
        {
          "trigger" => attrs[:activation_trigger].to_s,
          "conditions" => attrs[:activation_conditions].to_s
        }.compact_blank
      end

      def dependency_metadata_from(attrs)
        {
          "notes" => attrs[:dependency_notes].to_s,
          "depends_on" => {
            "forecast_scenario_ids" => scoped_ids(attrs[:depends_on_scenario_ids], @family.forecast_scenarios),
            "forecast_goal_ids" => scoped_ids(attrs[:depends_on_goal_ids], @family.forecast_goals)
          },
          "dependents" => {
            "forecast_scenario_ids" => scoped_ids(attrs[:depended_on_by_scenario_ids], @family.forecast_scenarios),
            "forecast_goal_ids" => scoped_ids(attrs[:depended_on_by_goal_ids], @family.forecast_goals)
          }
        }.compact_blank
      end

      def scoped_ids(values, relation)
        ids = Array(values).compact_blank
        return [] if ids.blank?

        relation.where(id: ids).pluck(:id)
      end

      def load_dependency_options
        @scenario_dependency_options = @family.forecast_scenarios.where.not(id: @plan&.forecast_scenario_id).ordered
        @goal_dependency_options = @family.forecast_goals.order(:name, :created_at)
      end

      def amount_rows
        exact_amounts = @plan.forecast_budget_plan_amounts.where(period_start_on: @period_start_on).index_by(&:amount_key)
        effective_amounts = @plan.effective_amounts_for(@period_start_on)
        inherited = inherited_values

        rows = []
        rows << build_amount_row(
          key: "expected_income",
          amount_type: "expected_income",
          label: t("forecasts.budget_plans.types.expected_income"),
          inherited_amount: inherited.fetch([ "expected_income", nil ], nil),
          exact_amounts: exact_amounts,
          effective_amounts: effective_amounts
        )
        rows << build_amount_row(
          key: "uncategorized_spending",
          amount_type: "uncategorized_spending",
          label: t("forecasts.budget_plans.types.uncategorized_spending"),
          inherited_amount: inherited.fetch([ "uncategorized_spending", nil ], nil),
          exact_amounts: exact_amounts,
          effective_amounts: effective_amounts
        )
        @family.categories.roots.alphabetically.each do |category|
          rows << build_amount_row(
            key: "category_#{category.id}",
            amount_type: "category_spending",
            category: category,
            label: category.name,
            inherited_amount: inherited.fetch([ "category_spending", category.id ], nil),
            exact_amounts: exact_amounts,
            effective_amounts: effective_amounts
          )
        end
        rows
      end

      def build_amount_row(key:, amount_type:, label:, inherited_amount:, exact_amounts:, effective_amounts:, category: nil)
        amount_key = [ amount_type, category&.id ]
        exact = exact_amounts[amount_key]
        effective = effective_amounts[amount_key]
        value = exact&.amount || effective&.amount || inherited_amount || 0
        slider_max = [ value.to_d * 2, 1_000.to_d ].max

        {
          key: key,
          amount_type: amount_type,
          category: category,
          label: label,
          inherited_amount: inherited_amount,
          exact_amount: exact,
          effective_amount: effective,
          value: value,
          input_value: input_value_for(value),
          slider_max: input_value_for(slider_max)
        }
      end

      def budget_plan_summary(rows)
        income = rows.select { |row| row.fetch(:amount_type) == "expected_income" }.sum { |row| row.fetch(:value).to_d }
        spending = rows.reject { |row| row.fetch(:amount_type) == "expected_income" }.sum { |row| row.fetch(:value).to_d }

        {
          income: income,
          spending: spending,
          net: income - spending,
          changed_count: rows.count { |row| row.fetch(:exact_amount).present? },
          projected_count: rows.count { |row| row.fetch(:exact_amount).blank? && row.fetch(:effective_amount).present? },
          inherited_count: rows.count { |row| row.fetch(:exact_amount).blank? && row.fetch(:effective_amount).blank? }
        }
      end

      def input_value_for(value)
        decimal = value.to_d
        decimal == decimal.to_i ? decimal.to_i : decimal
      end

      def inherited_values
        budget = inherited_budget
        return {} unless budget

        values = {
          [ "expected_income", nil ] => budget.expected_income,
          [ "uncategorized_spending", nil ] => 0.to_d
        }
        budget.budget_categories.each do |budget_category|
          next if budget_category.category.subcategory?

          values[[ "category_spending", budget_category.category_id ]] = budget_category.budgeted_spending
        end
        values
      end

      def inherited_budget
        @inherited_budget ||= @family.budgets
          .includes(budget_categories: :category)
          .where("start_date <= ?", @period_start_on)
          .order(start_date: :desc, id: :desc)
          .detect(&:initialized?)
      end

      def apply_amount_rows!(amounts)
        amounts.each_value do |row|
          amount_type = row["amount_type"].to_s
          next unless ForecastBudgetPlanAmount::AMOUNT_TYPES.include?(amount_type)

          category = amount_type == "category_spending" ? @family.categories.find_by(id: row["category_id"].presence) : nil
          exact = @plan.forecast_budget_plan_amounts.find_by(
            period_start_on: @period_start_on,
            amount_type: amount_type,
            category_id: category&.id
          )

          if row["amount"].blank?
            exact&.destroy!
            next
          end

          amount = exact || @plan.forecast_budget_plan_amounts.build(
            family: @family,
            period_start_on: @period_start_on,
            amount_type: amount_type,
            category: category
          )
          amount.assign_attributes(
            family: @family,
            amount: row["amount"],
            currency: @family.currency,
            note: row["note"]
          )
          amount.save!
        end
      end

      def build_template_from_plan!
        effective_amounts = @plan.effective_amounts_for(@period_start_on).values

        @family.forecast_budget_templates.transaction do
          template = @family.forecast_budget_templates.create!(
            name: params.dig(:forecast_budget_template, :name).presence || t("forecasts.budget_plans.template.default_name", name: @plan.forecast_scenario.name),
            description: @plan.forecast_scenario.description,
            currency: @plan.currency,
            source_metadata: {
              "forecast_budget_plan_id" => @plan.id,
              "period_start_on" => @period_start_on.iso8601
            }
          )

          effective_amounts.each do |amount|
            template.forecast_budget_template_amounts.create!(
              family: @family,
              category: amount.category,
              amount_type: amount.amount_type,
              amount: amount.amount,
              currency: amount.currency,
              note: amount.note,
              source_metadata: amount.source_metadata
            )
          end

          template
        end
      end
  end
end
