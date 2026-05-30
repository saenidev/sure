module Forecast
  class TransferClassifier
    def initialize(liquidity_classifier:, included_account_ids: nil)
      @liquidity_classifier = liquidity_classifier
      @included_account_ids = included_account_ids&.map(&:to_s)
    end

    def call(source_account:, destination_account:, amount:, date:, destination_amount: nil)
      return non_transfer(source_account: source_account, amount: amount, date: date) if destination_account.blank?

      kind = transfer_kind(source_account, destination_account)
      source_liquidity = source_account ? liquidity_classifier.call(source_account, on: date) : "cash"
      destination_liquidity = liquidity_classifier.call(destination_account, on: date)
      source_amount = amount.to_d.abs
      destination_amount = (destination_amount || source_amount).to_d.abs
      source_in_scope = endpoint_in_scope?(source_account)
      destination_in_scope = endpoint_in_scope?(destination_account)

      case kind
      when "funds_movement"
        {
          transaction_kind: kind,
          transfer: true,
          budget_flow_type: "none",
          expected_income: 0.to_d,
          expected_spending: 0.to_d,
          cash_delta: transfer_liquidity_delta(source_liquidity, destination_liquidity, source_amount, destination_amount, "cash", source_in_scope, destination_in_scope),
          liquid_delta: transfer_liquidity_delta(source_liquidity, destination_liquidity, source_amount, destination_amount, "liquid", source_in_scope, destination_in_scope),
          debt_delta: transfer_debt_delta(source_account, destination_account, source_amount, destination_amount, source_in_scope, destination_in_scope),
          portfolio_delta: transfer_portfolio_delta(source_account, destination_account, source_amount, destination_amount, source_in_scope, destination_in_scope),
          net_worth_delta: transfer_net_worth_delta(source_account, destination_account, source_amount, destination_amount, source_in_scope, destination_in_scope)
        }
      when "cc_payment"
        {
          transaction_kind: kind,
          transfer: true,
          budget_flow_type: "none",
          expected_income: 0.to_d,
          expected_spending: 0.to_d,
          cash_delta: transfer_liquidity_delta(source_liquidity, destination_liquidity, source_amount, destination_amount, "cash", source_in_scope, destination_in_scope),
          liquid_delta: transfer_liquidity_delta(source_liquidity, destination_liquidity, source_amount, destination_amount, "liquid", source_in_scope, destination_in_scope),
          debt_delta: transfer_debt_delta(source_account, destination_account, source_amount, destination_amount, source_in_scope, destination_in_scope),
          portfolio_delta: transfer_portfolio_delta(source_account, destination_account, source_amount, destination_amount, source_in_scope, destination_in_scope),
          net_worth_delta: transfer_net_worth_delta(source_account, destination_account, source_amount, destination_amount, source_in_scope, destination_in_scope)
        }
      when "loan_payment"
        budget_flow_type = source_in_scope ? "expense" : "none"
        {
          transaction_kind: kind,
          transfer: true,
          budget_flow_type: budget_flow_type,
          expected_income: 0.to_d,
          expected_spending: budget_flow_type == "expense" ? source_amount : 0.to_d,
          cash_delta: transfer_liquidity_delta(source_liquidity, destination_liquidity, source_amount, destination_amount, "cash", source_in_scope, destination_in_scope),
          liquid_delta: transfer_liquidity_delta(source_liquidity, destination_liquidity, source_amount, destination_amount, "liquid", source_in_scope, destination_in_scope),
          debt_delta: transfer_debt_delta(source_account, destination_account, source_amount, destination_amount, source_in_scope, destination_in_scope),
          portfolio_delta: transfer_portfolio_delta(source_account, destination_account, source_amount, destination_amount, source_in_scope, destination_in_scope),
          net_worth_delta: transfer_net_worth_delta(source_account, destination_account, source_amount, destination_amount, source_in_scope, destination_in_scope)
        }
      when "investment_contribution"
        budget_flow_type = source_in_scope ? "expense" : "none"
        {
          transaction_kind: kind,
          transfer: true,
          budget_flow_type: budget_flow_type,
          expected_income: 0.to_d,
          expected_spending: budget_flow_type == "expense" ? source_amount : 0.to_d,
          cash_delta: transfer_liquidity_delta(source_liquidity, destination_liquidity, source_amount, destination_amount, "cash", source_in_scope, destination_in_scope),
          liquid_delta: transfer_liquidity_delta(source_liquidity, destination_liquidity, source_amount, destination_amount, "liquid", source_in_scope, destination_in_scope),
          debt_delta: transfer_debt_delta(source_account, destination_account, source_amount, destination_amount, source_in_scope, destination_in_scope),
          portfolio_delta: transfer_portfolio_delta(source_account, destination_account, source_amount, destination_amount, source_in_scope, destination_in_scope),
          net_worth_delta: transfer_net_worth_delta(source_account, destination_account, source_amount, destination_amount, source_in_scope, destination_in_scope)
        }
      else
        non_transfer(source_account: source_account, amount: amount, date: date)
      end
    end

    private
      attr_reader :liquidity_classifier, :included_account_ids

      def endpoint_in_scope?(account)
        return false if account.blank?
        return true if included_account_ids.nil?

        included_account_ids.include?(account.id.to_s)
      end

      def transfer_kind(source_account, destination_account)
        if destination_account.loan?
          "loan_payment"
        elsif destination_account.liability?
          "cc_payment"
        elsif investment_like?(destination_account) && !investment_like?(source_account)
          "investment_contribution"
        else
          "funds_movement"
        end
      end

      def non_transfer(source_account:, amount:, date:)
        absolute_amount = amount.to_d.abs
        return liability_non_transfer(source_account, amount, absolute_amount) if source_account&.liability?

        sign = amount.to_d.negative? ? 1.to_d : -1.to_d
        source_liquidity = source_account ? liquidity_classifier.call(source_account, on: date) : "cash"
        portfolio_delta = investment_like?(source_account) ? sign * absolute_amount : 0.to_d
        cash_delta = source_liquidity == "cash" ? sign * absolute_amount : 0.to_d
        liquid_delta = source_liquidity.in?(%w[cash liquid]) ? sign * absolute_amount : 0.to_d

        if amount.to_d.negative?
          {
            transaction_kind: "standard",
            transfer: false,
            budget_flow_type: "income",
            expected_income: absolute_amount,
            expected_spending: 0.to_d,
            cash_delta: cash_delta,
            liquid_delta: liquid_delta,
            debt_delta: 0.to_d,
            portfolio_delta: portfolio_delta,
            net_worth_delta: absolute_amount,
            risk_flags: []
          }
        else
          {
            transaction_kind: "standard",
            transfer: false,
            budget_flow_type: "expense",
            expected_income: 0.to_d,
            expected_spending: absolute_amount,
            cash_delta: cash_delta,
            liquid_delta: liquid_delta,
            debt_delta: 0.to_d,
            portfolio_delta: portfolio_delta,
            net_worth_delta: -absolute_amount,
            risk_flags: []
          }
        end
      end

      def liability_non_transfer(source_account, amount, absolute_amount)
        if amount.to_d.negative?
          {
            transaction_kind: "standard",
            transfer: false,
            effect_label: "liability_payment_without_source",
            budget_flow_type: "none",
            expected_income: 0.to_d,
            expected_spending: 0.to_d,
            cash_delta: 0.to_d,
            liquid_delta: 0.to_d,
            debt_delta: -absolute_amount,
            portfolio_delta: 0.to_d,
            net_worth_delta: absolute_amount,
            risk_flags: [
              {
                "type" => "liability_payment_source_missing",
                "account_id" => source_account.id,
                "reason" => "non_transfer_liability_payment_does_not_identify_cash_source"
              }
            ]
          }
        else
          {
            transaction_kind: "standard",
            transfer: false,
            effect_label: "liability_charge",
            budget_flow_type: "expense",
            expected_income: 0.to_d,
            expected_spending: absolute_amount,
            cash_delta: 0.to_d,
            liquid_delta: 0.to_d,
            debt_delta: absolute_amount,
            portfolio_delta: 0.to_d,
            net_worth_delta: -absolute_amount,
            risk_flags: []
          }
        end
      end

      def transfer_liquidity_delta(source_liquidity, destination_liquidity, source_amount, destination_amount, bucket, source_in_scope, destination_in_scope)
        source_in_bucket = bucket == "cash" ? source_liquidity == "cash" : source_liquidity.in?(%w[cash liquid])
        destination_in_bucket = bucket == "cash" ? destination_liquidity == "cash" : destination_liquidity.in?(%w[cash liquid])

        source_delta = source_in_scope && source_in_bucket ? -source_amount : 0.to_d
        destination_delta = destination_in_scope && destination_in_bucket ? destination_amount : 0.to_d
        source_delta + destination_delta
      end

      def transfer_debt_delta(source_account, destination_account, source_amount, destination_amount, source_in_scope, destination_in_scope)
        source_delta = source_in_scope && source_account&.liability? ? source_amount : 0.to_d
        destination_delta = destination_in_scope && destination_account&.liability? ? -destination_amount : 0.to_d
        source_delta + destination_delta
      end

      def transfer_portfolio_delta(source_account, destination_account, source_amount, destination_amount, source_in_scope, destination_in_scope)
        source_delta = source_in_scope && investment_like?(source_account) ? -source_amount : 0.to_d
        destination_delta = destination_in_scope && investment_like?(destination_account) ? destination_amount : 0.to_d
        source_delta + destination_delta
      end

      def transfer_net_worth_delta(source_account, destination_account, source_amount, destination_amount, source_in_scope, destination_in_scope)
        source_delta = scoped_endpoint_net_worth_delta(source_account, -source_amount) if source_in_scope
        destination_delta = scoped_endpoint_net_worth_delta(destination_account, destination_amount) if destination_in_scope

        source_delta.to_d + destination_delta.to_d
      end

      def scoped_endpoint_net_worth_delta(account, signed_asset_flow)
        return 0.to_d if account.blank?

        signed_asset_flow
      end

      def investment_like?(account)
        account&.investment? || account&.crypto?
      end
  end
end
