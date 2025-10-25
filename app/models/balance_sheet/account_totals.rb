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

    def account_rows
      boolean_type = ActiveRecord::Type::Boolean.new

      @account_rows ||= query.map do |account_row|
        AccountRow.new(
          account: account_row,
          converted_balance: account_row.converted_balance,
          is_syncing: sync_status_monitor.account_syncing?(account_row),
          missing_exchange_rate: boolean_type.cast(account_row.missing_exchange_rate)
        )
      end
    end

    def cache_key
      key_components = [ "balance_sheet_account_rows", exchange_rates_cache_version ].compact.join("_")

      family.build_cache_key(key_components, invalidate_on_data_updates: true)
    end

    def exchange_rates_cache_version
      currencies = visible_accounts.distinct.pluck(:currency)
      return nil if currencies.blank?

      ExchangeRate.where(from_currency: currencies, to_currency: family.currency)
                  .maximum(:updated_at)
                  &.to_i
    end

    def query
      @query ||= Rails.cache.fetch(cache_key) do
        family_currency = family.currency
        rate_sql = ActiveRecord::Base.send(
          :sanitize_sql_array,
          [
            "CASE WHEN accounts.currency = :family_currency THEN 1 ELSE exchange_rates.rate END",
            { family_currency: family_currency }
          ]
        )
        missing_rate_sql = ActiveRecord::Base.send(
          :sanitize_sql_array,
          [
            "CASE WHEN accounts.currency = :family_currency THEN FALSE WHEN exchange_rates.rate IS NULL THEN TRUE ELSE FALSE END AS missing_exchange_rate",
            { family_currency: family_currency }
          ]
        )

        visible_accounts
          .joins(ActiveRecord::Base.sanitize_sql_array([
            "LEFT JOIN exchange_rates ON exchange_rates.date = ? AND accounts.currency = exchange_rates.from_currency AND exchange_rates.to_currency = ?",
            Date.current,
            family_currency
          ]))
          .select(
            "accounts.*",
            "SUM(accounts.balance * #{rate_sql}) AS converted_balance",
            missing_rate_sql
          )
          .group(:classification, :accountable_type, :id)
          .to_a
      end
    end
end
