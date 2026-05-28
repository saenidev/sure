module AccountableResource
  extend ActiveSupport::Concern

  included do
    include Periodable, StreamExtensions

    before_action :set_account, only: [ :show ]
    before_action :set_manageable_account, only: [ :edit, :update ]
    before_action :set_link_options, only: :new
  end

  class_methods do
    def permitted_accountable_attributes(*attrs)
      @permitted_accountable_attributes = attrs if attrs.any?
      @permitted_accountable_attributes ||= [ :id ]
    end
  end

  def new
    @account = Current.family.accounts.build(
      currency: Current.family.currency,
      accountable: accountable_type.new
    )
  end

  def show
    @chart_view = params[:chart_view] || "balance"
    @q = params.fetch(:q, {}).permit(:search)
    entries = @account.entries.search(@q).reverse_chronological

    @pagy, @entries = pagy(entries, limit: safe_per_page(10))
  end

  def edit
  end

  def create
    if invalid_current_balance_submitted?
      @account = Current.family.accounts.build(
        account_params.except(:return_to, :opening_balance_date).merge(owner: Current.user)
      )
      @error_message = "Balance must be a number"
      render :new, status: :unprocessable_entity
      return
    end

    opening_balance_date = begin
      account_params[:opening_balance_date].presence&.to_date
    rescue Date::Error
      nil
    end || (Time.zone.today - 2.years)
    Account.transaction do
      @account = Current.family.accounts.create_and_sync(
        account_params.except(:return_to, :opening_balance_date).merge(owner: Current.user),
        opening_balance_date: opening_balance_date
      )
      @account.lock_saved_attributes!
    end

    redirect_to account_params[:return_to].presence || @account, notice: t("accounts.create.success", type: accountable_type.name.underscore.humanize)
  end

  def update
    if opening_anchor_balance_submitted?
      result = @account.set_opening_anchor_balance(balance: opening_anchor_balance_value)
      unless result.success?
        @error_message = result.error
        render :edit, status: :unprocessable_entity
        return
      end
    end

    if invalid_current_balance_submitted?
      @error_message = "Balance must be a number"
      render :edit, status: :unprocessable_entity
      return
    end

    # Handle balance update if the value actually changed
    if current_balance_submitted? && current_balance_value != @account.balance
      result = @account.set_current_balance(current_balance_value)
      unless result.success?
        @error_message = result_error_message(result)
        render :edit, status: :unprocessable_entity
        return
      end
    end

    # Update remaining account attributes. Note: currency is intentionally allowed
    # here so all account types (depositories, credit cards, loans, etc.) can
    # have their currency changed via this shared update path.
    update_params = account_params.except(:return_to, :balance, :opening_balance_date)
    unless @account.update(update_params)
      @error_message = @account.errors.full_messages.join(", ")
      render :edit, status: :unprocessable_entity
      return
    end

    @account.lock_saved_attributes!
    redirect_back_or_to account_path(@account), notice: t("accounts.update.success", type: accountable_type.name.underscore.humanize)
  end

  private
    def set_link_options
      account_type_name = accountable_type.name

      # Get all available provider configs dynamically for this account type
      @provider_configs = Provider::Factory.connection_configs_for_account_type(
        account_type: account_type_name,
        family: Current.family
      )
    end

    def accountable_type
      controller_name.classify.constantize
    end

    def set_account
      @account = Current.user.accessible_accounts.find(params[:id])
    end

    def set_manageable_account
      @account = Current.user.accessible_accounts.find(params[:id])
      require_account_permission!(@account)
    end

    def account_params
      params.require(:account).permit(
        :name, :balance, :subtype, :currency, :accountable_type, :return_to,
        :opening_balance_date,
        :institution_name, :institution_domain, :notes,
        accountable_attributes: self.class.permitted_accountable_attributes
      )
    end

    def opening_anchor_balance_submitted?
      return false unless @account.loan?
      return false if @account.linked?
      return false unless account_params.dig(:accountable_attributes, :initial_balance).present?
      return false if opening_anchor_balance_value.nil?

      opening_anchor_balance_value != @account.opening_anchor_balance
    end

    def opening_anchor_balance_param
      account_params.dig(:accountable_attributes, :initial_balance)
    end

    def opening_anchor_balance_value
      return @opening_anchor_balance_value if defined?(@opening_anchor_balance_value)

      @opening_anchor_balance_value = parsed_decimal(opening_anchor_balance_param)
    end

    def current_balance_submitted?
      account_params[:balance].present?
    end

    def invalid_current_balance_submitted?
      current_balance_submitted? && current_balance_value.nil?
    end

    def current_balance_value
      return @current_balance_value if defined?(@current_balance_value)

      @current_balance_value = parsed_decimal(account_params[:balance])
    end

    def parsed_decimal(value)
      parsed = BigDecimal(value.to_s)
      parsed if parsed.finite?
    rescue ArgumentError
      nil
    end

    def result_error_message(result)
      return result.error if result.respond_to?(:error)
      return result.error_message if result.respond_to?(:error_message)

      "Unable to update balance"
    end
end
