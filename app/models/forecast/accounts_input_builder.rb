module Forecast
  class AccountsInputBuilder
    def initialize(family:, user:, money_converter:, scenario_ids:, included_account_scope:)
      @family = family
      @user = user
      @money_converter = money_converter
      @scenario_ids = Array(scenario_ids).compact_blank
      @included_account_scope = included_account_scope
    end

    def call
      included_account_scope.relation.map do |account|
        balance = money_converter.convert(amount: account.balance, currency: account.currency, source: "account:#{account.id}:balance")
        cash_balance = money_converter.convert(amount: account.cash_balance, currency: account.currency, source: "account:#{account.id}:cash_balance")

        {
          id: account.id,
          name: account.name,
          accountable_type: account.accountable_type,
          classification: account.classification,
          liquidity_class: liquidity_classifier.call(account, on: money_converter.as_of),
          balance: balance.amount,
          cash_balance: cash_balance.amount,
          currency: money_converter.currency,
          native_balance: balance.native_amount,
          native_cash_balance: cash_balance.native_amount,
          native_currency: account.currency,
          source_snapshot: {
            "id" => account.id,
            "name" => account.name,
            "accountable_type" => account.accountable_type,
            "classification" => account.classification,
            "liquidity_class" => liquidity_classifier.call(account, on: money_converter.as_of),
            "balance" => money_converter.snapshot_for(balance),
            "cash_balance" => money_converter.snapshot_for(cash_balance)
          },
          risk_flags: balance.risk_flags + cash_balance.risk_flags
        }
      end
    end

    private
      attr_reader :family, :user, :money_converter, :scenario_ids, :included_account_scope

      def liquidity_classifier
        @liquidity_classifier ||= Forecast::LiquidityClassifier.new(family: family, scenario_ids: scenario_ids)
      end
  end
end
