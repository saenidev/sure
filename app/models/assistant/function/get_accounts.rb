class Assistant::Function::GetAccounts < Assistant::Function
  # Provider account class => column holding the date the institution last
  # stamped the balance. A connection can sync successfully while one bank
  # keeps serving an old balance; only this date reveals that. Providers
  # without such a column report null rather than a guess.
  PROVIDER_BALANCE_DATE_COLUMNS = {
    "SimplefinAccount" => :balance_date,
    "IbkrAccount" => :report_date
  }.freeze

  class << self
    def name
      "get_accounts"
    end

    def description
      <<~INSTRUCTIONS
        Use this to see what accounts the user has along with their current balances.

        Linked accounts include last_synced_at, last_sync_status and last_sync_error
        for their provider connection (null for manual accounts), and
        provider_balance_as_of: when the institution last dated this account's
        balance. A successful sync can still carry an old balance date.
        last_entry_on is the date of the account's newest transaction or balance
        entry; for a manual account it shows when anyone last updated it.

        Returns account ids. Use them for account_ids filters in other tools.

        Loan and credit card accounts also carry a `terms` object with the
        borrowing terms the user recorded (rate, term, monthly payment, APR,
        minimum payment). A key is absent when the user never entered it, so
        treat a missing key as unknown rather than as zero.

        A loan's `interest_rate` is the rate in force on `as_of_date`. When a
        variable-rate loan's recorded rate changes have moved it,
        `base_interest_rate` is the rate the loan started at.

        For a fixed-rate loan, `monthly_payment` is the contracted repayment,
        still reported after the term has ended. For a variable-rate loan it is
        the next scheduled repayment on or after `as_of_date`, already sized at
        every change recorded to take effect by that payment, so it can reflect
        a change `interest_rate` does not show yet. It is absent once every
        scheduled payment is past. A change the user has not recorded is not
        reflected in either field.

        Note on `terms.available_credit`: providers disagree on its meaning
        (some report the credit limit, others the remaining credit), so confirm
        with the user before reasoning about headroom on a linked card.

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
    as_of_date = Date.current

    accounts = accounts_scope(include_series).to_a
    sync_status = SyncStatus.new(accounts)
    last_entry_on = Entry.where(account_id: accounts.map(&:id)).where(date: ..Date.current)
                         .group(:account_id).maximum(:date)

    {
      as_of_date: as_of_date,
      accounts: accounts.map do |account|
        payload = {
          id: account.id,
          name: account.name,
          balance: account.balance,
          currency: account.currency,
          balance_formatted: account.balance_money.format,
          classification: account.classification,
          type: account.accountable_type,
          subtype: account.subtype,
          start_date: account.start_date,
          is_linked: account.linked?,
          provider: account.provider_name,
          status: account.status,
          provider_balance_as_of: provider_balance_as_of(account),
          last_entry_on: last_entry_on[account.id]&.iso8601
        }.merge(sync_status.for(account))

        terms = account_terms(account, as_of_date)
        payload[:terms] = terms if terms.present?

        if include_series
          series = historical_balances(account, period)
          payload[:historical_balances] = series if series
        end
        payload
      end
    }
  end

  private
    def provider_balance_as_of(account)
      # An account can be linked through several providers (and older SimpleFIN
      # links sit on the account directly); the oldest date is the one to warn on.
      providers = account.account_providers.map(&:provider) + [ account.simplefin_account ]
      providers.compact.uniq.filter_map { |provider|
        column = PROVIDER_BALANCE_DATE_COLUMNS[provider.class.name]
        column && provider.public_send(column)
      }.min_by(&:to_date)&.iso8601
    end

    # No balances preload: the series goes through Balance::ChartSeriesBuilder,
    # which runs its own query keyed by account ids.
    def accounts_scope(_include_series)
      user.accessible_accounts.visible.includes(
        :accountable,
        { account_providers: :provider },
        { plaid_account: :plaid_item },
        { simplefin_account: :simplefin_item }
      )
    end

    # The accountable record holds the only borrowing terms Sure stores, and
    # this tool used to drop the delegated record entirely, so an assistant
    # asked "what is my loan costing me" had nothing to answer with even though
    # the rate was sitting in the database. Only the types that carry financial
    # terms are serialized; the rest (Depository, Property, ...) return nil and
    # the key is omitted.
    def account_terms(account, as_of_date)
      case account.accountable
      when Loan then loan_terms(account.accountable, as_of_date)
      when CreditCard then credit_card_terms(account.accountable)
      end
    end

    # `compact` throughout: a nil rate must read as "the user never entered it",
    # never as zero. An entirely empty hash is dropped by the caller.
    #
    # Rate and repayment are read the way the loan's Overview tab reads them, so
    # the assistant never quotes a figure the user's own loan page contradicts.
    # Once a variable loan has a recorded rate change, the `interest_rate` column
    # is only the rate it started at, not the one it charges.
    def loan_terms(loan, as_of_date)
      interest_rate = loan.current_variable_rate(as_of_date)
      monthly_payment = payment_in_force(loan, as_of_date)
      original_balance = loan.original_balance

      {
        interest_rate: interest_rate,
        base_interest_rate: (loan.interest_rate if loan.interest_rate != interest_rate),
        rate_type: loan.rate_type,
        term_months: loan.term_months,
        monthly_payment: monthly_payment&.amount,
        monthly_payment_formatted: monthly_payment&.format,
        original_balance: original_balance&.amount,
        original_balance_formatted: original_balance&.format
      }.compact
    end

    # Loan#monthly_payment stays nil for a variable loan, which has no single
    # contracted repayment. It always has the next one, though, sized at every
    # change recorded before it, and that is what the Overview tab quotes. Nil
    # when there is no schedule or it has run out, so the key is omitted rather
    # than reported as zero.
    def payment_in_force(loan, as_of_date)
      return loan.monthly_payment unless loan.variable_rate_type?

      loan.amortization_schedule&.payment_in_force(as_of_date)
    end

    def credit_card_terms(credit_card)
      {
        apr: credit_card.apr,
        minimum_payment: credit_card.minimum_payment,
        annual_fee: credit_card.annual_fee,
        available_credit: credit_card.available_credit,
        expiration_date: credit_card.expiration_date
      }.compact
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
