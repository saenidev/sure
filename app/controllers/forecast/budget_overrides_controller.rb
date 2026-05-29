module Forecast
  # Authoring for forecast-owned monthly budget adjustments. These rows let a
  # user project a different expected income, parent-category spending, or
  # uncategorized spending for a month WITHOUT touching the real Budget /
  # BudgetCategory records the rest of the app reads from.
  #
  # Inherits the family-scoped base controller, so every lookup goes through
  # `Current.family.forecast_budget_overrides`. A cross-family id therefore
  # raises ActiveRecord::RecordNotFound (-> 404) instead of trusting params[:id].
  #
  # The editing surface mirrors the Budgets feature: a month picker drives a
  # grid that shows, per parent category, the inherited budget value (read-only,
  # never bootstrapped) alongside the forecast override. Income and uncategorized
  # overrides carry no category. An optional scenario scope must fully cover the
  # chosen period (the model's scenario_covers_entire_budget_period validation is
  # the backstop; the scenario select is pre-filtered to covering scenarios).
  class BudgetOverridesController < BaseController
    before_action :set_period, only: %i[index]
    before_action :set_override, only: %i[edit update destroy]

    # GET /forecast/budget_overrides
    # Month grid for the selected period and optional scenario scope. Eager-loads
    # the active overrides and the inherited budget once so the grid never N+1s
    # over categories.
    def index
      @scenario = scoped_scenario
      @scenario_options = scenarios_covering_period
      @rows = grid_rows
    end

    # GET /forecast/budget_overrides/new
    def new
      @override = @family.forecast_budget_overrides.new(
        period_start_on: param_to_period(params[:period]),
        override_type: override_type_param,
        category_id: category_id_param,
        forecast_scenario_id: scenario_id_param,
        status: "active",
        amount: 0,
        currency: @family.currency
      )
    end

    # POST /forecast/budget_overrides
    def create
      @override = @family.forecast_budget_overrides.new(override_params)

      if @override.save
        redirect_to forecast_budget_overrides_path(redirect_query), notice: t(".success")
      else
        @existing_override = existing_active_override_for(@override)
        render :new, status: :unprocessable_entity
      end
    end

    # GET /forecast/budget_overrides/:id/edit
    def edit
    end

    # PATCH/PUT /forecast/budget_overrides/:id
    def update
      if @override.update(override_params)
        redirect_to forecast_budget_overrides_path(redirect_query), notice: t(".success")
      else
        @existing_override = existing_active_override_for(@override)
        render :edit, status: :unprocessable_entity
      end
    end

    # DELETE /forecast/budget_overrides/:id
    def destroy
      @override.destroy
      redirect_to forecast_budget_overrides_path(redirect_query), notice: t(".success")
    end

    private
      def set_override
        @override = @family.forecast_budget_overrides.find(params[:id])
        @period_start_on = @override.period_start_on
        @scenario = @override.forecast_scenario
      end

      # Canonicalize the requested period the same way the model does so the grid
      # and the persisted override agree on the family's month start.
      def set_period
        @period_start_on = param_to_period(params[:period])
        @period_end_on = @family.custom_month_end_for(@period_start_on)
      end

      def param_to_period(param)
        base = if param.present?
          begin
            Budget.param_to_date(param, family: @family)
          rescue ArgumentError
            Date.current
          end
        else
          Date.current
        end

        @family.custom_month_start_for(base)
      end

      # Scenario scope from params, resolved through the family association so a
      # foreign id is a 404 rather than a way to peek at another family's scenario.
      def scoped_scenario
        return if params[:scenario_id].blank?

        @family.forecast_scenarios.find(params[:scenario_id])
      end

      # Only scenarios whose window fully covers the period are valid scopes for
      # an override in this period (matches the model validation). Pre-filtering
      # here keeps the select from offering options the model would reject.
      def scenarios_covering_period
        @family.forecast_scenarios.ordered.select do |scenario|
          scenario_covers_period?(scenario)
        end
      end

      def scenario_covers_period?(scenario)
        starts_after = scenario.starts_on.present? && scenario.starts_on > @period_start_on
        ends_before = scenario.ends_on.present? && scenario.ends_on < @period_end_on
        !(starts_after || ends_before)
      end

      # Build the grid rows for the period: the income and uncategorized rows
      # (no category) plus one row per PARENT category (subcategories are not
      # valid override targets per the model). Each row carries the inherited
      # budget value (read-only) and the active forecast override if one exists.
      def grid_rows
        parents = @family.categories.roots.alphabetically.to_a
        overrides_by_key = active_overrides_for_period.index_by { |o| override_key(o) }
        inherited = inherited_budgeted_by_category_id

        rows = []
        rows << build_row(type: "expected_income", category: nil, inherited: inherited_expected_income, overrides_by_key: overrides_by_key)
        rows << build_row(type: "uncategorized_spending", category: nil, inherited: inherited[nil], overrides_by_key: overrides_by_key)
        parents.each do |category|
          rows << build_row(type: "category_spending", category: category, inherited: inherited[category.id], overrides_by_key: overrides_by_key)
        end
        rows
      end

      def build_row(type:, category:, inherited:, overrides_by_key:)
        {
          override_type: type,
          category: category,
          inherited_amount: inherited,
          override: overrides_by_key[[ type, category&.id ]]
        }
      end

      # Active overrides for the period + scenario scope, eager-loaded so the grid
      # rows do not N+1 over the category each one points at.
      def active_overrides_for_period
        @family.forecast_budget_overrides
          .includes(:category)
          .where(status: "active", period_start_on: @period_start_on, forecast_scenario_id: @scenario&.id)
      end

      def override_key(override)
        [ override.override_type, override.category_id ]
      end

      # Read the inherited budgeted spending per category WITHOUT bootstrapping a
      # real Budget. If the family has not initialized a budget for this period the
      # inherited values are simply absent (nil) and the grid shows a dash.
      def inherited_budgeted_by_category_id
        budget = inherited_budget
        return {} unless budget

        budget.budget_categories.each_with_object({}) do |bc, memo|
          memo[bc.category_id] = bc.budgeted_spending
        end
      end

      def inherited_expected_income
        inherited_budget&.expected_income
      end

      def inherited_budget
        return @inherited_budget if defined?(@inherited_budget)

        @inherited_budget = @family.budgets
          .includes(:budget_categories)
          .find_by(start_date: @period_start_on, end_date: @period_end_on)
      end

      # Find the existing active override that collides with the one we tried to
      # save, so the form can offer "edit the existing one instead" rather than
      # 500-ing on the uniqueness validation.
      def existing_active_override_for(override)
        return if override.status != "active"

        @family.forecast_budget_overrides
          .where.not(id: override.id)
          .find_by(
            status: "active",
            period_start_on: override.period_start_on,
            override_type: override.override_type,
            forecast_scenario_id: override.forecast_scenario_id,
            category_id: override.category_id
          )
      end

      # Strong params: only user-authorable attributes. family_id is NEVER
      # permitted (set server-side via the family association). category_id and
      # forecast_scenario_id are permitted but constrained to the family by the
      # model's associations_belong_to_family validation.
      def override_params
        permitted = params.require(:forecast_budget_override).permit(
          :period_start_on, :override_type, :amount, :currency,
          :category_id, :forecast_scenario_id, :status
        )

        permitted[:currency] = permitted[:currency].presence if permitted.key?(:currency)
        permitted
      end

      def override_type_param
        type = params[:override_type].presence
        ForecastBudgetOverride::OVERRIDE_TYPES.include?(type) ? type : "category_spending"
      end

      def category_id_param
        return if override_type_param != "category_spending"

        params[:category_id].presence
      end

      def scenario_id_param
        params[:scenario_id].presence
      end

      # Carry the period + scenario scope through redirects so the grid returns to
      # the same month/scenario the user was editing.
      def redirect_query
        query = { period: Budget.date_to_param(@override.period_start_on) }
        query[:scenario_id] = @override.forecast_scenario_id if @override.forecast_scenario_id.present?
        query
      end
  end
end
