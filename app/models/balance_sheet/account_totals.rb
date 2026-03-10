class BalanceSheet::AccountTotals
  def initialize(family, sync_status_monitor:)
    @family = family
    @sync_status_monitor = sync_status_monitor
  end

  def asset_accounts
    @asset_accounts ||= account_rows.filter { |t| t.classification == "asset" }
  end

  def liability_accounts
    @liability_accounts ||= account_rows.filter { |t| t.classification == "liability" }
  end

  private
    attr_reader :family, :sync_status_monitor

    AccountRow = Data.define(:account, :converted_balance, :is_syncing, :missing_exchange_rate) do
      def syncing? = is_syncing
      def missing_exchange_rate? = missing_exchange_rate

      # Allows Rails path helpers to generate URLs from the wrapper
      def to_param = account.to_param
      delegate_missing_to :account
    end

    def visible_accounts
      @visible_accounts ||= family.accounts.visible.with_attached_logo
    end

    # Wraps each account in an AccountRow with its converted balance and sync status.
    def account_rows
      @account_rows ||= accounts.map do |account|
        AccountRow.new(
          account: account,
          converted_balance: converted_balance_for(account),
          is_syncing: sync_status_monitor.account_syncing?(account),
          missing_exchange_rate: missing_exchange_rate_for(account)
        )
      end
    end

    # Returns the cache key for storing visible account IDs, invalidated on data updates.
    def cache_key
      family.build_cache_key(
        "balance_sheet_account_ids",
        invalidate_on_data_updates: true
      )
    end

    # Loads visible accounts, caching their IDs to speed up subsequent requests.
    # On cache miss, loads records once and writes IDs; on hit, filters by cached IDs.
    def accounts
      @accounts ||= begin
        ids = Rails.cache.read(cache_key)

        if ids
          visible_accounts.where(id: ids).to_a
        else
          records = visible_accounts.to_a
          Rails.cache.write(cache_key, records.map(&:id))
          records
        end
      end
    end

    # Batch-fetches today's exchange rates for all foreign currencies present in accounts.
    # Unlike ExchangeRate.rates_for, this preserves nil when a rate is unavailable so
    # balance-sheet totals can exclude foreign-currency accounts with missing rates.
    # @return [Hash{String => Numeric,nil}] currency code to rate mapping
    def exchange_rates
      @exchange_rates ||= begin
        foreign_currencies = accounts.filter_map { |a| a.currency if a.currency != family.currency }
        foreign_currencies.uniq.each_with_object({}) do |currency, map|
          rate = ExchangeRate.find_or_fetch_rate(from: currency, to: family.currency, date: Date.current)
          map[currency] = rate&.rate
        end
      end
    end

    # Converts an account's balance to the family's currency using pre-fetched exchange rates.
    # @return [BigDecimal, nil] balance in the family's currency, or nil when rate is unavailable
    def converted_balance_for(account)
      return account.balance if account.currency == family.currency

      rate = exchange_rates[account.currency]
      return nil if rate.nil?

      account.balance * rate
    end

    def missing_exchange_rate_for(account)
      account.currency != family.currency && exchange_rates[account.currency].nil?
    end
end
