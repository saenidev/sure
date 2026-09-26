class Assistant::Function::GetAccounts < Assistant::Function
  class << self
    def name
      "get_accounts"
    end

    def description
      <<~INSTRUCTIONS
        Use this to see what accounts the user has along with their current balances.

        Linked accounts include last_synced_at, last_sync_status and last_sync_error
        for their provider connection (null for manual accounts).

        Returns account ids. Use them for account_ids filters in other tools.

        Pass include_balance_series: true only when the user asks about balance
        history; the series is omitted by default to keep responses small.
      INSTRUCTIONS
    end
  end

  def strict_mode?
    false
  end

  def params_schema
    build_schema(
      required: [],
      properties: {
        include_balance_series: {
          type: "boolean",
          description: "Include a historical balance series per account (defaults to false)"
        },
        series_period: {
          type: "string",
          enum: Period::PERIODS.keys,
          description: "Period for the balance series (defaults to last_365_days)"
        }
      }
    )
  end

  def call(params = {})
    include_series = params["include_balance_series"] == true
    period = series_period(params)

    accounts = accounts_scope(include_series).to_a
    sync_status = SyncStatus.new(accounts)

    {
      as_of_date: Date.current,
      accounts: accounts.map do |account|
        payload = {
          id: account.id,
          name: account.name,
          balance: account.balance,
          currency: account.currency,
          balance_formatted: account.balance_money.format,
          classification: account.classification,
          type: account.accountable_type,
          start_date: account.start_date,
          is_linked: account.linked?,
          provider: account.provider_name,
          status: account.status
        }.merge(sync_status.for(account))

        if include_series
          series = historical_balances(account, period)
          payload[:historical_balances] = series if series
        end
        payload
      end
    }
  end

  private
    # No balances preload: the series goes through Balance::ChartSeriesBuilder,
    # which runs its own query keyed by account ids.
    def accounts_scope(_include_series)
      user.accessible_accounts.visible.includes(
        { account_providers: :provider },
        { plaid_account: :plaid_item },
        { simplefin_account: :simplefin_item }
      )
    end

    def historical_balances(account, period)
      effective_start = [ account.start_date, period.start_date ].max
      # An account whose start date lies beyond the period (start_date derives
      # from the first entry, which can be future-dated) simply has no series;
      # it must not fail the whole accounts listing.
      return nil if effective_start > period.end_date

      effective = Period.custom(start_date: effective_start, end_date: period.end_date)
      balance_series = account.balance_series(period: effective, interval: effective.interval)

      to_ai_time_series(balance_series)
    end

    def series_period(params)
      key = params["series_period"].to_s

      Period.valid_key?(key) ? Period.from_key(key) : Period.from_key("last_365_days")
    end

    # Sync health of each account's provider connection. Nightly provider syncs
    # run on the connection ("item", e.g. SimplefinItem); account syncs are its
    # children, and a failure there fails the item sync too, so the item's latest
    # sync is the one that reflects whether the provider fetch worked. Manual
    # accounts have no item and report nulls.
    class SyncStatus
      ERROR_LIMIT = 200
      URL_WITH_USERINFO = %r{\b[a-z][a-z0-9+.\-]*://[^\s/@]+@\S*}i
      EMPTY = { last_synced_at: nil, last_sync_status: nil, last_sync_error: nil }.freeze

      def initialize(accounts)
        preload_provider_items(accounts)
        @items_by_account_id = accounts.index_by(&:id).transform_values { |account| item_for(account) }
        items = @items_by_account_id.values.compact
        @latest = Sync.latest_by_syncable(items)
        @latest_completed = Sync.latest_completed_by_syncable(items)
      end

      def for(account)
        item = @items_by_account_id[account.id]
        return EMPTY.dup unless item

        key = [ item.class.base_class.name, item.id ]
        latest = @latest[key]
        completed = @latest_completed[key]

        {
          last_synced_at: completed&.completed_at&.iso8601,
          last_sync_status: latest&.status,
          last_sync_error: latest && sanitize_error(latest)
        }
      end

      private
        # Provider accounts are polymorphic and name their item association
        # per provider (simplefin_item, ibkr_item, ...), so preload it per class
        # to keep adapter#item from querying once per account.
        def preload_provider_items(accounts)
          provider_accounts = accounts.flat_map { |account| account.account_providers.map(&:provider) }.compact
          provider_accounts.group_by(&:class).each do |klass, records|
            associations = klass.reflect_on_all_associations(:belongs_to)
              .select { |reflection| reflection.name.to_s.end_with?("_item") && !reflection.polymorphic? }
              .map(&:name)
            next if associations.empty?

            ActiveRecord::Associations::Preloader.new(records: records, associations: associations).call
          end
        end

        # Mirrors Account::Linkable#provider: the first AccountProvider wins,
        # then the legacy plaid/simplefin foreign keys.
        def item_for(account)
          account_provider = account.account_providers.first
          item = account_provider && provider_item(account_provider)
          item ||= account.plaid_account&.plaid_item
          item ||= account.simplefin_account&.simplefin_item
          item if item.class.include?(Syncable)
        end

        def provider_item(account_provider)
          account_provider.adapter&.item
        rescue Provider::Factory::AdapterNotFoundError, NotImplementedError
          nil
        end

        # Same fallback as Syncable#sync_error: an item sync failed by a child
        # account sync carries the error on the child.
        def sanitize_error(sync)
          message = sync.error.presence || sync.children.filter_map { |child| child.error.presence }.first
          return nil if message.blank?

          message.gsub(URL_WITH_USERINFO, "[redacted url]").squish.truncate(ERROR_LIMIT)
        end
    end
end
