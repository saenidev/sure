module Forecast
  # Per-account liquidity classification overrides. Inherits the family-scoped
  # base controller, so every lookup goes through
  # `Current.family.forecast_account_liquidity_settings`. A cross-family id
  # therefore raises ActiveRecord::RecordNotFound (-> 404) instead of trusting
  # params[:id].
  #
  # The classified account is constrained to `Current.family.accounts`: the
  # `account_id` param is resolved through the family association on create, so a
  # foreign account id raises RecordNotFound (-> 404). The model's
  # `records_belong_to_family` validation is the server-side backstop, and its
  # `date_window_does_not_overlap` validation surfaces overlapping windows for the
  # same account+scenario as a 422.
  class AccountLiquiditySettingsController < BaseController
    before_action :set_setting, only: %i[edit update destroy]
    before_action :set_account, only: %i[create update]

    # GET /forecast/account_liquidity_settings
    # Lists the family's visible accounts with their effective classification and
    # any baseline override. Reuses the workspace query object so the list shares
    # one eager-loaded query path (no N+1 over account types).
    def index
      @workspace = Forecast::Workspace.new(family: @family)
    end

    # GET /forecast/account_liquidity_settings/new
    def new
      @setting = @family.forecast_account_liquidity_settings.new(liquidity_class: "cash")
    end

    # POST /forecast/account_liquidity_settings
    def create
      @setting = @family.forecast_account_liquidity_settings.new(setting_params)
      @setting.account = @account if @account

      if @setting.save
        redirect_to forecast_account_liquidity_settings_path, notice: t(".success")
      else
        render :new, status: :unprocessable_entity
      end
    end

    # GET /forecast/account_liquidity_settings/:id/edit
    def edit
    end

    # PATCH/PUT /forecast/account_liquidity_settings/:id
    def update
      attributes = setting_params
      attributes = attributes.merge(account: @account) if @account

      if @setting.update(attributes)
        redirect_to forecast_account_liquidity_settings_path, notice: t(".success")
      else
        render :edit, status: :unprocessable_entity
      end
    end

    # DELETE /forecast/account_liquidity_settings/:id
    def destroy
      @setting.destroy
      redirect_to forecast_account_liquidity_settings_path, notice: t(".success")
    end

    private
      def set_setting
        @setting = @family.forecast_account_liquidity_settings.find(params[:id])
      end

      # Resolve the classified account through the family association so a foreign
      # account id is a 404 rather than a way to classify another family's
      # account. Skipped when no account_id is supplied (validation surfaces it).
      def set_account
        account_id = params.dig(:forecast_account_liquidity_setting, :account_id)
        return if account_id.blank?

        @account = @family.accounts.find(account_id)
      end

      # Strong params: only user-authorable attributes. family_id is NEVER
      # permitted (set server-side via the family association). account_id is
      # resolved separately through the family association (set_account) so it can
      # only ever reference a family account. forecast_scenario_id is permitted but
      # validated against the family by the model.
      def setting_params
        params.require(:forecast_account_liquidity_setting).permit(
          :liquidity_class, :forecast_scenario_id, :starts_on, :ends_on
        )
      end
  end
end
