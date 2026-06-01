class AccountsController < ApplicationController
  include StreamExtensions
  include SimplefinItems::MapsHelper

  before_action :set_account, only: %i[show sparkline sync set_default remove_default]
  before_action :set_manageable_account, only: %i[toggle_active destroy unlink confirm_unlink select_provider]
  include Periodable

  def index
    @accessible_account_ids = Current.user.accessible_accounts.pluck(:id)
    @manual_accounts = family.accounts
          .listable_manual
          .where(id: @accessible_account_ids)
          .includes(:accountable, :account_providers, :plaid_account, :simplefin_account, :syncs)
          .order(:name)
    @plaid_items = visible_provider_items(family.plaid_items.ordered.includes({ syncs: :children }, plaid_accounts: [ :account, { account_provider: :account } ]))
    @simplefin_items = visible_provider_items(family.simplefin_items.ordered.includes(syncs: :children))
    @lunchflow_items = visible_provider_items(family.lunchflow_items.ordered.includes(:accounts, { syncs: :children }, lunchflow_accounts: :account_provider))
    @enable_banking_items = visible_provider_items(family.enable_banking_items.ordered.includes(:accounts, { syncs: :children }, enable_banking_accounts: :account_provider))
    @coinstats_items = visible_provider_items(family.coinstats_items.ordered.includes(:accounts, { syncs: :children }, coinstats_accounts: :account_provider))
    @mercury_items = visible_provider_items(family.mercury_items.ordered.includes(:accounts, { syncs: :children }, mercury_accounts: :account_provider))
    @brex_items = visible_provider_items(family.brex_items.ordered.includes(:accounts, { syncs: :children }, brex_accounts: :account_provider))
    @coinbase_items = visible_provider_items(family.coinbase_items.ordered.includes({ syncs: :children }, coinbase_accounts: { account_provider: :account }))
    @snaptrade_items = visible_provider_items(family.snaptrade_items.ordered.includes({ syncs: :children }, snaptrade_accounts: { account_provider: :account }))
    @ibkr_items = visible_provider_items(family.ibkr_items.ordered.includes({ syncs: :children }, ibkr_accounts: { account_provider: :account }))
    @indexa_capital_items = visible_provider_items(family.indexa_capital_items.ordered.includes(:accounts, { syncs: :children }, indexa_capital_accounts: :account_provider))
    @sophtron_items = visible_provider_items(family.sophtron_items.ordered.includes(:accounts, { syncs: :children }, sophtron_accounts: :account_provider))

    preload_simplefin_accounts_for_cards

    # Build sync stats maps for all providers
    build_sync_stats_maps

    # Prevent Turbo Drive from caching this page to ensure fresh account lists
    expires_now
    render layout: "settings"
  end

  def new
    # Get all registered providers with any credentials configured
    @provider_configs = Provider::Factory.registered_adapters.flat_map do |adapter_class|
      adapter_class.connection_configs(family: family)
    end
  end

  def sync_all
    family.sync_later
    redirect_to accounts_path, notice: t("accounts.sync_all.syncing")
  end

  def show
    @chart_view = params[:chart_view] || "balance"
    @tab = params[:tab]
    @q = params.fetch(:q, {}).permit(:search, status: [])
    entries = @account.entries.where(excluded: false).search(@q).reverse_chronological.includes(:entryable)
    if statement_tab_active?
      build_statement_tab_data
      return render_statement_tab_frame if statement_tab_frame_request?
    end

    @pagy, @entries = pagy(
      entries,
      limit: safe_per_page,
      params: request.query_parameters.except("tab").merge("tab" => "activity")
    )
    Transaction::ActivitySecurityPreloader.new(@entries).preload

    @activity_feed_data = Account::ActivityFeedData.new(@account, @entries)
  end

  def sync
    unless @account.syncing?
      if @account.linked?
        # Sync all provider items for this account
        # Each provider item will trigger an account sync when complete
        @account.account_providers.each do |account_provider|
          item = account_provider.adapter&.item
          item&.sync_later if item && !item.syncing?
        end
      else
        # Manual accounts just need balance materialization
        @account.sync_later
      end
    end

    redirect_to account_path(@account)
  end

  def sparkline
    etag_key = @account.family.build_cache_key("#{@account.id}_sparkline_#{Account::Chartable::SPARKLINE_CACHE_VERSION}", invalidate_on_data_updates: true)

    # Short-circuit with 304 Not Modified when the client already has the latest version.
    # We defer the expensive series computation until we know the content is stale.
    if stale?(etag: etag_key, last_modified: @account.family.latest_sync_completed_at)
      @sparkline_series = @account.sparkline_series
      render layout: false
    end
  end

  def toggle_active
    if @account.active?
      @account.disable!
    elsif @account.disabled?
      @account.enable!
    end
    redirect_to accounts_path
  end

  def set_default
    unless @account.eligible_for_transaction_default?
      redirect_to accounts_path, alert: t("accounts.set_default.depository_only")
      return
    end

    Current.user.update!(default_account: @account)
    redirect_to accounts_path
  end

  def remove_default
    Current.user.update!(default_account: nil)
    redirect_to accounts_path
  end

  def destroy
    if @account.linked?
      redirect_to account_path(@account), alert: t("accounts.destroy.cannot_delete_linked")
    else
      begin
        @account.destroy_later
        redirect_to accounts_path, notice: t("accounts.destroy.success", type: @account.accountable_type)
      rescue => e
        Rails.logger.error "Failed to schedule account #{@account.id} for deletion: #{e.message}"
        redirect_to accounts_path, alert: t("accounts.destroy.failed")
      end
    end
  end

  def confirm_unlink
    unless @account.linked?
      redirect_to account_path(@account), alert: t("accounts.unlink.not_linked")
    end
  end

  def unlink
    unless @account.linked?
      redirect_to account_path(@account), alert: t("accounts.unlink.not_linked")
      return
    end

    begin
      Account.transaction do
        # Detach holdings from provider links before destroying them
        provider_link_ids = @account.account_providers.pluck(:id)
        if provider_link_ids.any?
          Holding.where(account_provider_id: provider_link_ids).update_all(account_provider_id: nil)
        end

        # Capture provider accounts before clearing links (so we can destroy them)
        simplefin_account_to_destroy = @account.simplefin_account

        # Remove new system links (account_providers join table)
        # SnaptradeAccount records are preserved (not destroyed) so users can relink later.
        # This follows the Plaid pattern where the provider account survives as "unlinked".
        # SnapTrade has limited connection slots (5 free), so preserving the record avoids
        # wasting a slot on reconnect.
        @account.account_providers.destroy_all

        # Remove legacy system links (foreign keys)
        @account.update!(plaid_account_id: nil, simplefin_account_id: nil)

        # Destroy the SimplefinAccount record so it doesn't cause stale account issues
        # This is safe because:
        # - Account data (transactions, holdings, balances) lives on the Account, not SimplefinAccount
        # - SimplefinAccount only caches API data which is regenerated on reconnect
        # - If user reconnects SimpleFin later, a new SimplefinAccount will be created
        simplefin_account_to_destroy&.destroy!
      end

      redirect_to accounts_path, notice: t("accounts.unlink.success")
    rescue ActiveRecord::RecordInvalid => e
      redirect_to account_path(@account), alert: t("accounts.unlink.error", error: e.message)
    rescue StandardError => e
      Rails.logger.error "Failed to unlink account #{@account.id}: #{e.message}"
      redirect_to account_path(@account), alert: t("accounts.unlink.error", error: t("accounts.unlink.generic_error"))
    end
  end

  def select_provider
    if @account.linked?
      redirect_to account_path(@account), alert: t("accounts.select_provider.already_linked")
      return
    end

    account_type_name = @account.accountable_type

    # Get all available provider configs dynamically for this account type
    provider_configs = Provider::Factory.connection_configs_for_account_type(
      account_type: account_type_name,
      family: family
    )

    # Build available providers list with paths resolved for this specific account
    # Filter out providers that don't support linking to existing accounts
    @available_providers = provider_configs.filter_map do |config|
      next unless config[:existing_account_path].present?
      {
        name: config[:name],
        key: config[:key],
        description: config[:description],
        path: config[:existing_account_path].call(@account.id)
      }
    end

    if @available_providers.empty?
      redirect_to account_path(@account), alert: t("accounts.select_provider.no_providers")
    end
  end

  private
    def family
      Current.family
    end

    def set_account
      @account = Current.user.accessible_accounts.find(params[:id])
    end

    def set_manageable_account
      @account = Current.user.accessible_accounts.find(params[:id])
      permission = @account.permission_for(Current.user)
      unless permission.in?([ :owner, :full_control ])
        respond_to do |format|
          format.html { redirect_to account_path(@account), alert: t("accounts.not_authorized") }
          format.turbo_stream { stream_redirect_to(account_path(@account), alert: t("accounts.not_authorized")) }
        end
        nil
      end
    end

    def visible_provider_items(items)
      items.select do |item|
        Current.user.admin? ||
          (item.respond_to?(:accounts) && (item.accounts.map(&:id) & @accessible_account_ids).any?)
      end
    end

    def preload_simplefin_accounts_for_cards
      return if @simplefin_items.empty?

      accounts_by_item_id = SimplefinAccount
        .where(simplefin_item_id: @simplefin_items.map(&:id))
        .includes(:account, account_provider: :account)
        .group_by(&:simplefin_item_id)

      @simplefin_items.each do |item|
        item.preload_accounts_for_card(accounts_by_item_id[item.id] || [])
        item.association(:simplefin_accounts).target = accounts_by_item_id[item.id] || []
        item.association(:simplefin_accounts).loaded!
      end
    end

    def build_statement_tab_data
      return unless statement_tab_active?

      @statement_coverage = AccountStatement::Coverage.for_year(@account, params[:statement_year])
      @account_statements = @account.account_statements.with_attached_original_file.ordered.to_a
      @statement_reconciliation_statuses = AccountStatement.reconciliation_statuses_for(@account_statements, account: @account)
      permission = @account.permission_for(Current.user)
      @can_manage_statements = AccountStatement.statement_manager?(Current.user) &&
        permission.in?([ :owner, :full_control ])
    end

    def statement_tab_frame_request?
      turbo_frame_request? && request.headers["Turbo-Frame"] == helpers.dom_id(@account, :statements_tab)
    end

    def render_statement_tab_frame
      render partial: "accounts/show/statements_frame", locals: statement_tab_locals, layout: false
    end

    def statement_tab_locals
      {
        account: @account,
        coverage: @statement_coverage,
        statements: @account_statements,
        reconciliation_statuses: @statement_reconciliation_statuses,
        can_manage_statements: @can_manage_statements
      }
    end

    def statement_tab_active?
      @tab == "statements"
    end

    # Builds sync stats maps for all provider types to avoid N+1 queries in views
    def build_sync_stats_maps
      # SimpleFIN sync stats
      build_simplefin_maps_for(@simplefin_items)

      # Plaid sync stats
      @plaid_sync_stats_map = {}
      @plaid_items.each do |item|
        latest_sync = latest_sync_for(item)
        @plaid_sync_stats_map[item.id] = latest_sync&.sync_stats || {}
      end

      # Lunchflow sync stats
      @lunchflow_sync_stats_map = {}
      @lunchflow_items.each do |item|
        latest_sync = latest_sync_for(item)
        @lunchflow_sync_stats_map[item.id] = latest_sync&.sync_stats || {}
      end

      # Enable Banking sync stats
      @enable_banking_sync_stats_map = {}
      @enable_banking_latest_sync_error_map = {}
      @enable_banking_items.each do |item|
        latest_sync = latest_sync_for(item)
        @enable_banking_sync_stats_map[item.id] = latest_sync&.sync_stats || {}
        @enable_banking_latest_sync_error_map[item.id] = latest_sync&.error
      end

      # CoinStats sync stats
      @coinstats_sync_stats_map = {}
      @coinstats_items.each do |item|
        latest_sync = latest_sync_for(item)
        @coinstats_sync_stats_map[item.id] = latest_sync&.sync_stats || {}
      end

      # Sophtron sync stats
      @sophtron_sync_stats_map = {}
      @sophtron_items.each do |item|
        latest_sync = latest_sync_for(item)
        @sophtron_sync_stats_map[item.id] = latest_sync&.sync_stats || {}
      end

      # Mercury sync stats
      @mercury_sync_stats_map = {}
      @mercury_items.each do |item|
        latest_sync = latest_sync_for(item)
        @mercury_sync_stats_map[item.id] = latest_sync&.sync_stats || {}
      end

      # Brex sync stats
      @brex_sync_stats_map = {}
      @brex_account_counts_map = {}
      @brex_institutions_count_map = {}
      @brex_items.each do |item|
        latest_sync = latest_sync_for(item)
        @brex_sync_stats_map[item.id] = latest_sync&.sync_stats || {}
        brex_accounts = item.brex_accounts.to_a
        linked_count = brex_accounts.count { |brex_account| brex_account.account_provider.present? }
        total_count = brex_accounts.count
        @brex_account_counts_map[item.id] = {
          linked: linked_count,
          unlinked: total_count - linked_count,
          total: total_count
        }
        @brex_institutions_count_map[item.id] = brex_accounts
          .filter_map(&:institution_metadata)
          .uniq { |institution| institution["name"] || institution["institution_name"] }
          .count
      end

      # Coinbase sync stats
      @coinbase_sync_stats_map = {}
      @coinbase_unlinked_count_map = CoinbaseAccount
        .where(coinbase_item_id: @coinbase_items.map(&:id))
        .left_joins(:account_provider)
        .where(account_providers: { id: nil })
        .group(:coinbase_item_id)
        .count

      @coinbase_items.each do |item|
        latest_sync = latest_sync_for(item)
        @coinbase_sync_stats_map[item.id] = latest_sync&.sync_stats || {}
      end

      # IndexaCapital sync stats
      @indexa_capital_sync_stats_map = {}
      @indexa_capital_items.each do |item|
        latest_sync = latest_sync_for(item)
        @indexa_capital_sync_stats_map[item.id] = latest_sync&.sync_stats || {}
      end
    end

    def latest_sync_for(item)
      if item.syncs.loaded?
        item.syncs.max_by { |sync| [ sync.created_at || Time.at(0), sync.id || 0 ] }
      else
        item.syncs.ordered.first
      end
    end
end
