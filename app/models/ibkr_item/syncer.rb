class IbkrItem::Syncer
  include SyncStats::Collector

  attr_reader :ibkr_item

  def initialize(ibkr_item)
    @ibkr_item = ibkr_item
  end

  def perform_sync(sync)
    sync.update!(status_text: "Checking IBKR credentials...") if sync.respond_to?(:status_text)
    unless ibkr_item.credentials_configured?
      ibkr_item.update!(status: :requires_update)
      raise Provider::IbkrFlex::ConfigurationError, "IBKR credentials are missing."
    end

    sync.update!(status_text: "Importing IBKR accounts...") if sync.respond_to?(:status_text)
    ibkr_item.import_latest_ibkr_data

    sync.update!(status_text: "Checking account configuration...") if sync.respond_to?(:status_text)
    collect_setup_stats(sync, provider_accounts: ibkr_item.ibkr_accounts.to_a)

    unlinked_accounts = ibkr_item.ibkr_accounts.left_joins(:account_provider).where(account_providers: { id: nil })
    linked_accounts = ibkr_item.ibkr_accounts.joins(:account).merge(Account.visible)

    if unlinked_accounts.any?
      ibkr_item.update!(pending_account_setup: true)
      sync.update!(status_text: "#{unlinked_accounts.count} IBKR account(s) need setup...") if sync.respond_to?(:status_text)
    else
      ibkr_item.update!(pending_account_setup: false)
    end

    if linked_accounts.any?
      sync.update!(status_text: "Processing holdings and activity...") if sync.respond_to?(:status_text)
      processing_results = ibkr_item.process_accounts
      collect_ibkr_import_stats(sync, processing_results)

      sync.update!(status_text: "Calculating balances...") if sync.respond_to?(:status_text)
      ibkr_item.schedule_account_syncs(
        parent_sync: sync,
        window_start_date: sync.window_start_date,
        window_end_date: sync.window_end_date
      )

      account_ids = linked_accounts.includes(:account).filter_map { |provider_account| provider_account.account&.id }
      collect_transaction_stats(sync, account_ids: account_ids, source: "ibkr") if account_ids.any?
      collect_trades_stats(sync, account_ids: account_ids, source: "ibkr") if account_ids.any?
      collect_holdings_stats(sync, holdings_count: count_holdings, label: "processed")
      collect_flex_data_quality_warning(sync, linked_accounts)
    end

    collect_health_stats(sync, errors: nil)
  rescue Provider::IbkrFlex::AuthenticationError, Provider::IbkrFlex::ConfigurationError => e
    ibkr_item.update!(status: :requires_update)
    collect_health_stats(sync, errors: [ { message: e.message, category: "auth_error" } ])
    raise
  rescue => e
    collect_health_stats(sync, errors: [ { message: e.message, category: "sync_error" } ])
    raise
  end

  def perform_post_sync
  end

  private

    def count_holdings
      ibkr_item.ibkr_accounts.sum { |account| Array(account.raw_holdings_payload).size }
    end

    def collect_flex_data_quality_warning(sync, linked_ibkr_accounts)
      accounts_missing_positions_or_trades = linked_ibkr_accounts.select do |account|
        cash_present = Array(account.raw_cash_report_payload).any? || account.cash_balance.to_d.nonzero?
        trades = Array((account.raw_activities_payload || {}).with_indifferent_access[:trades])

        cash_present && account.raw_holdings_payload.blank? && trades.blank?
      end

      return if accounts_missing_positions_or_trades.empty?

      collect_data_quality_stats(sync,
        warnings: accounts_missing_positions_or_trades.size,
        details: [ {
          message: I18n.t("provider_warnings.ibkr_missing_positions_or_trades"),
          severity: "warning"
        } ]
      )
    end

    def collect_ibkr_import_stats(sync, processing_results)
      return unless sync.respond_to?(:sync_stats)

      account_imports = Array(processing_results).map do |processing_result|
        ibkr_account = ibkr_item.ibkr_accounts.find { |account| account.id == processing_result[:ibkr_account_id] }
        next unless ibkr_account

        activities = (ibkr_account.raw_activities_payload || {}).with_indifferent_access
        result = (processing_result[:result] || {}).with_indifferent_access

        {
          "ibkr_account_id" => ibkr_account.id,
          "success" => processing_result[:success],
          "raw_holdings_rows" => Array(ibkr_account.raw_holdings_payload).size,
          "raw_trade_rows" => Array(activities[:trades]).size,
          "raw_cash_transaction_rows" => Array(activities[:cash_transactions]).size,
          "holdings_imported" => result[:holdings].to_i,
          "trades_imported" => result[:trades].to_i,
          "transactions_imported" => result[:transactions].to_i,
          "error" => processing_result[:error]
        }.compact
      end.compact

      merge_sync_stats(sync, {
        "ibkr_account_imports" => account_imports,
        "ibkr_raw_holdings_rows" => account_imports.sum { |account| account["raw_holdings_rows"].to_i },
        "ibkr_raw_trade_rows" => account_imports.sum { |account| account["raw_trade_rows"].to_i },
        "ibkr_holdings_imported" => account_imports.sum { |account| account["holdings_imported"].to_i },
        "ibkr_trades_imported" => account_imports.sum { |account| account["trades_imported"].to_i }
      })

      collect_ibkr_zero_import_warnings(sync, account_imports)
    end

    def collect_ibkr_zero_import_warnings(sync, account_imports)
      details = []

      account_imports.each do |account_import|
        if account_import["raw_holdings_rows"].to_i.positive? && account_import["holdings_imported"].to_i.zero?
          details << {
            message: I18n.t("provider_warnings.ibkr_zero_holdings_imported"),
            severity: "warning"
          }
        end

        if account_import["raw_trade_rows"].to_i.positive? && account_import["trades_imported"].to_i.zero?
          details << {
            message: I18n.t("provider_warnings.ibkr_zero_trades_imported"),
            severity: "warning"
          }
        end
      end

      return if details.empty?

      collect_data_quality_stats(sync, warnings: details.size, details: details)
    end
end
