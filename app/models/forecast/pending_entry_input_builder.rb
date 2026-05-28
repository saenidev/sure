module Forecast
  class PendingEntryInputBuilder
    def initialize(family:, user:, start_on:, end_on:, money_converter:, included_account_scope:, scenario_ids: [])
      @family = family
      @user = user
      @start_on = start_on
      @end_on = end_on
      @money_converter = money_converter
      @included_account_scope = included_account_scope
      @scenario_ids = Array(scenario_ids).compact_blank
    end

    def call
      family.entries.visible.pending
        .where(date: start_on..end_on, excluded: false)
        .where(account_id: included_account_scope.ids)
        .order(:date, :account_id, :id)
        .preload(:account, entryable: [ :category, :transfer_as_inflow, :transfer_as_outflow ])
        .reject { |entry| duplicate_pending?(entry) || ignored_transfer_side?(entry) }
        .map { |entry| payload(entry) }
    end

    private
      attr_reader :family, :user, :start_on, :end_on, :money_converter, :included_account_scope, :scenario_ids

      def payload(entry, status: "pending", link: nil)
        transfer = transfer_for(entry)
        source_entry = transfer_source_entry_for(entry, transfer)
        converted = money_converter.convert(amount: source_entry.amount.to_d.abs, currency: source_entry.currency, source: "pending_entry:#{entry.id}", as_of: source_entry.date)
        effect = pending_effect(entry, converted.amount)
        category = effect.fetch(:category, entry.transaction? ? entry.transaction.category : nil)
        {
          id: entry.id,
          account_id: entry.account_id,
          destination_account_id: effect.fetch(:destination_account_id, nil),
          date: entry.date,
          name: entry.name,
          amount: converted.amount,
          currency: money_converter.currency,
          native_amount: converted.native_amount,
          native_currency: converted.native_currency,
          direction: effect.fetch(:direction),
          status: status,
          transaction_kind: effect.fetch(:transaction_kind),
          budget_flow_type: effect.fetch(:budget_flow_type),
          category_id: category&.id || effect.fetch(:category_id, nil),
          expected_income: effect.fetch(:expected_income),
          expected_spending: effect.fetch(:expected_spending),
          pending_income: status == "pending" ? effect.fetch(:pending_income) : 0.to_d,
          pending_spending: status == "pending" ? effect.fetch(:pending_spending) : 0.to_d,
          cash_delta: effect.fetch(:cash_delta),
          liquid_delta: effect.fetch(:liquid_delta),
          debt_delta: effect.fetch(:debt_delta),
          portfolio_delta: effect.fetch(:portfolio_delta),
          net_worth_delta: effect.fetch(:net_worth_delta),
          source_snapshot: {
            "id" => entry.id,
            "name" => entry.name,
            "date" => entry.date.iso8601,
            "account_id" => entry.account_id,
            "destination_account_id" => effect.fetch(:destination_account_id, nil),
            "source_entry_id" => source_entry.id,
            "source_entry_account_id" => source_entry.account_id,
            "source_entry_date" => source_entry.date.iso8601,
            "category" => category_snapshot(category),
            "signed_entry_amount" => entry.amount.to_s,
            "transaction_kind" => effect.fetch(:transaction_kind),
            "effect_label" => effect.fetch(:effect_label, nil),
            "transfer_key" => transfer ? transfer_key_for(transfer) : nil,
            "forecast_event_link_id" => link&.id,
            "forecast_event_id" => link&.forecast_event_id,
            "forecast_event_occurrence_on" => link&.occurrence_on&.iso8601,
            "money" => money_converter.snapshot_for(converted),
            "destination_money" => effect.fetch(:destination_money_snapshot, {})
          },
          risk_flags: converted.risk_flags + effect.fetch(:risk_flags, [])
        }
      end

      def pending_effect(entry, amount)
        transfer = transfer_for(entry)
        return transfer_effect(entry, transfer, amount) if transfer.present?
        return liability_pending_effect(entry, amount) if entry.account&.liability?

        kind = entry.transaction? ? entry.transaction.kind : "standard"
        budget_forced_expense = kind.in?(%w[investment_contribution loan_payment])
        direction = budget_forced_expense ? "spending" : (entry.amount.to_d.negative? ? "income" : "spending")
        sign = entry.amount.to_d.negative? ? 1.to_d : -1.to_d
        liquidity_class = liquidity_classifier.call(entry.account, on: entry.date)
        budget_excluded = Transaction::BUDGET_EXCLUDED_KINDS.include?(kind) || budget_scope_excluded_account?(entry.account) || internal_investment_movement?(entry.transaction)
        budget_flow_type = budget_excluded ? "none" : (direction == "spending" ? "expense" : "income")
        category_id = budget_flow_type == "expense" && entry.transaction? ? entry.transaction.category_id : nil
        cash_delta = liquidity_class == "cash" ? sign * amount : 0.to_d
        liquid_delta = liquidity_class.in?(%w[cash liquid]) ? sign * amount : 0.to_d
        debt_delta = liquidity_class == "debt" ? -sign * amount : 0.to_d
        portfolio_delta = if kind == "investment_contribution"
          investment_like?(entry.account) ? sign * amount : 0.to_d
        elsif investment_like?(entry.account)
          sign * amount
        else
          0.to_d
        end

        case kind
        when "debt_interest"
          net_worth_delta = -amount
          debt_delta = amount
        else
          net_worth_delta = sign * amount
        end

        {
          transaction_kind: kind,
          direction: direction,
          budget_flow_type: budget_flow_type,
          category_id: category_id,
          expected_income: budget_flow_type == "income" ? amount : 0.to_d,
          expected_spending: budget_flow_type == "expense" ? amount : 0.to_d,
          pending_income: budget_excluded || direction != "income" ? 0.to_d : amount,
          pending_spending: budget_excluded || direction != "spending" ? 0.to_d : amount,
          cash_delta: cash_delta,
          liquid_delta: liquid_delta,
          debt_delta: debt_delta,
          portfolio_delta: portfolio_delta,
          net_worth_delta: net_worth_delta
        }
      end

      def liability_pending_effect(entry, amount)
        signed_amount = entry.amount.to_d.negative? ? -amount : amount
        effect = transfer_classifier.call(
          source_account: entry.account,
          destination_account: nil,
          amount: signed_amount,
          date: entry.date
        )

        effect.merge(
          direction: effect.fetch(:budget_flow_type) == "expense" ? "spending" : "debt_payment",
          pending_income: effect.fetch(:expected_income),
          pending_spending: effect.fetch(:expected_spending)
        )
      end

      def transfer_effect(entry, transfer, amount)
        destination_amount = converted_transfer_destination_amount(entry, transfer)
        effect = transfer_classifier.call(
          source_account: transfer.from_account || entry.account,
          destination_account: transfer.to_account,
          amount: amount,
          destination_amount: destination_amount&.fetch(:amount),
          date: entry.date
        )

        effect.merge(
          direction: "transfer",
          destination_account_id: transfer.to_account&.id,
          category: entry.transaction&.category || transfer_default_category(effect),
          pending_income: effect.fetch(:expected_income),
          pending_spending: effect.fetch(:expected_spending)
        ).tap do |result|
          result[:risk_flags] = result.fetch(:risk_flags, []) + Array(destination_amount&.fetch(:risk_flags))
          result[:destination_money_snapshot] = destination_amount ? money_converter.snapshot_for(destination_amount.fetch(:converted)) : {}
        end
      end

      def converted_transfer_destination_amount(entry, transfer)
        destination_entry = transfer.inflow_transaction&.entry
        return nil if destination_entry.blank?
        return nil unless transfer.to_account.present? && included_account_scope.id_values.include?(transfer.to_account.id)

        converted = money_converter.convert(
          amount: destination_entry.amount.to_d.abs,
          currency: destination_entry.currency,
          source: "transfer:#{transfer.id}:destination_entry:#{destination_entry.id}",
          as_of: destination_entry.date
        )

        { amount: converted.amount, converted: converted, risk_flags: converted.risk_flags }
      end

      def transfer_source_entry_for(entry, transfer)
        source_entry = transfer&.outflow_transaction&.entry
        return entry if source_entry.blank?
        return source_entry if included_account_scope.id_values.include?(source_entry.account_id)

        entry
      end

      def transfer_for(entry)
        return nil unless entry.transaction?

        entry.transaction.transfer_as_outflow || entry.transaction.transfer_as_inflow
      end

      def transfer_key_for(transfer)
        return nil if transfer.blank?

        [ transfer.outflow_transaction_id, transfer.inflow_transaction_id ].compact.map(&:to_s).sort.join(":")
      end

      def duplicate_pending?(entry)
        entry.transaction? && entry.transaction.has_potential_duplicate?
      end

      def budget_scope_excluded_account?(account)
        account.present? && family.tax_advantaged_account_ids.include?(account.id)
      end

      def internal_investment_movement?(transaction)
        transaction&.investment_activity_label.in?(Transaction::INTERNAL_MOVEMENT_LABELS)
      end

      def investment_like?(account)
        account&.investment? || account&.crypto?
      end

      def ignored_transfer_side?(entry)
        transfer = transfer_for(entry)
        return false if transfer.blank?

        source_in_scope = transfer.from_account.present? && included_account_scope.id_values.include?(transfer.from_account.id)
        destination_in_scope = transfer.to_account.present? && included_account_scope.id_values.include?(transfer.to_account.id)
        return true unless source_in_scope || destination_in_scope

        entry.transaction.transfer_as_inflow.present? && source_in_scope && destination_in_scope
      end

      def transfer_classifier
        @transfer_classifier ||= Forecast::TransferClassifier.new(
          liquidity_classifier: liquidity_classifier,
          included_account_ids: included_account_scope.id_values
        )
      end

      def liquidity_classifier
        @liquidity_classifier ||= Forecast::LiquidityClassifier.new(family: family, scenario_ids: scenario_ids)
      end

      def category_snapshot(category)
        return nil if category.blank?

        {
          "id" => category.id,
          "name" => category.name,
          "parent_id" => category.parent_id,
          "parent_name" => category.parent&.name
        }
      end

      def transfer_default_category(effect)
        case effect.fetch(:transaction_kind)
        when "loan_payment"
          loan_payments_category
        when "investment_contribution"
          investment_contributions_category
        end
      end

      def loan_payments_category
        names = I18n.available_locales.map { |locale| I18n.t("models.category.defaults.loan_payments", locale: locale) }.uniq
        family.categories.where(name: names).order(:created_at, :id).first
      end

      def investment_contributions_category
        family.categories.where(name: Category.all_investment_contributions_names).order(:created_at, :id).first
      end
  end
end
