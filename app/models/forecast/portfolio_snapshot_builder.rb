module Forecast
  class PortfolioSnapshotBuilder
    def initialize(family:, user:, money_converter:, run_date:)
      @family = family
      @user = user
      @money_converter = money_converter
      @run_date = run_date
    end

    def call
      holdings = current_holdings.to_a
      converted_accounts = investment_accounts.map { |account| converted_account(account) }
      holding_rows = holdings.map { |holding| holding_payload(holding) }
      day_change = day_change_for(holdings)

      {
        portfolio_value: converted_accounts.sum { |row| row.fetch(:balance).to_d },
        cash_balance: converted_accounts.sum { |row| row.fetch(:cash_balance).to_d },
        currency: money_converter.currency,
        day_change: day_change.fetch(:amount),
        accounts: converted_accounts,
        holdings: holding_rows,
        market_data_quality: market_data_quality(holdings),
        risk_flags: converted_accounts.flat_map { |row| row.fetch(:risk_flags, []) } + holding_rows.flat_map { |row| row.fetch(:risk_flags, []) } + day_change.fetch(:risk_flags)
      }
    end

    private
      attr_reader :family, :user, :money_converter, :run_date

      def investment_accounts
        @investment_accounts ||= family.accounts.visible
          .where(accountable_type: %w[Investment Crypto])
          .included_in_finances_for(user)
          .order(:accountable_type, :name, :id)
      end

      def current_holdings
        investment_accounts.includes(:holdings).flat_map { |account| current_holdings_for_account(account) }
      end

      def current_holdings_for_account(account)
        scope =
          if (provider_snapshot_date = account.latest_provider_holdings_snapshot_date)
            account.holdings.where.not(account_provider_id: nil).where(date: provider_snapshot_date)
          else
            account.holdings
              .where(currency: account.currency)
              .select("DISTINCT ON (security_id) holdings.*")
              .order(:security_id, date: :desc, id: :desc)
          end

        scope.where.not(qty: 0).includes(:security, :account).to_a.sort_by { |holding| [ holding.account_id, holding.security_id.to_s, holding.date || Date.new(0), holding.id ] }
      end

      def converted_account(account)
        balance = money_converter.convert(amount: account.balance, currency: account.currency, source: "portfolio_account:#{account.id}:balance")
        cash_balance = money_converter.convert(amount: account.cash_balance, currency: account.currency, source: "portfolio_account:#{account.id}:cash_balance")

        {
          account_id: account.id,
          balance: balance.amount,
          cash_balance: cash_balance.amount,
          source_snapshot: {
            "account_id" => account.id,
            "balance" => money_converter.snapshot_for(balance),
            "cash_balance" => money_converter.snapshot_for(cash_balance)
          },
          risk_flags: balance.risk_flags + cash_balance.risk_flags
        }
      end

      def holding_payload(holding)
        converted = money_converter.convert(amount: holding.amount, currency: holding.currency, source: "holding:#{holding.id}:amount", as_of: holding.date)

        {
          holding_id: holding.id,
          account_id: holding.account_id,
          security_id: holding.security_id,
          ticker: holding.security.ticker,
          qty: holding.qty.to_d,
          amount: converted.amount,
          currency: money_converter.currency,
          native_amount: converted.native_amount,
          native_currency: converted.native_currency,
          date: holding.date,
          source_snapshot: {
            "holding_id" => holding.id,
            "money" => money_converter.snapshot_for(converted)
          },
          risk_flags: converted.risk_flags
        }
      end

      def day_change_for(holdings)
        amount = 0.to_d
        risk_flags = []

        holdings.each do |holding|
          trend = holding.day_change
          next if trend.blank?

          value = trend.value.respond_to?(:amount) ? trend.value.amount : trend.value
          converted = money_converter.convert(amount: value, currency: holding.currency, source: "holding:#{holding.id}:day_change", as_of: holding.date)
          amount += converted.amount
          risk_flags.concat(converted.risk_flags)
        end

        { amount: amount, risk_flags: risk_flags }
      end

      def market_data_quality(holdings)
        security_ids = holdings.map(&:security_id).uniq
        provisional_count = Security::Price.where(security_id: security_ids, provisional: true).where(date: (run_date - 7.days)..run_date).count

        {
          provisional_recent_price_count: provisional_count,
          as_of: run_date
        }
      end
  end
end
