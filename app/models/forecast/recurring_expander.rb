module Forecast
  class RecurringExpander
    def initialize(family:, user:, start_on:, end_on:, money_converter:, scenario_ids:, included_account_scope:)
      @family = family
      @user = user
      @start_on = start_on
      @end_on = end_on
      @money_converter = money_converter
      @scenario_ids = Array(scenario_ids).compact_blank
      @included_account_scope = included_account_scope
    end

    def call
      return [] if family.recurring_transactions_disabled?

      scope.map { |recurring| expand(recurring) }.flatten
    end

    private
      attr_reader :family, :user, :start_on, :end_on, :money_converter, :scenario_ids, :included_account_scope

      def scope
        family.recurring_transactions.accessible_by(user).active
          .where(
            "(destination_account_id IS NULL AND (account_id IS NULL OR account_id IN (:ids))) OR " \
            "(destination_account_id IS NOT NULL AND (account_id IN (:ids) OR destination_account_id IN (:ids)))",
            ids: included_account_scope.id_values
          )
          .includes(:account, :destination_account, :merchant)
          .order(:next_expected_date, :expected_day_of_month, :name, :id)
      end

      def expand(recurring)
        first_date = [ recurring.next_expected_date || start_on, start_on ].max
        current = clamp_day(first_date.year, first_date.month, recurring.expected_day_of_month)
        current = clamp_day(current.next_month.year, current.next_month.month, recurring.expected_day_of_month) while current < start_on
        rows = []

        while current <= end_on
          converted = if unmodeled_cross_currency_recurring_transfer?(recurring)
            money_converter.convert(amount: 0, currency: recurring.currency, source: "recurring_transaction:#{recurring.id}:unmodeled_cross_currency")
          else
            money_converter.convert(amount: amount_for(recurring), currency: recurring.currency, source: "recurring_transaction:#{recurring.id}")
          end
          effect = recurring_effect(recurring, converted, current)
          effect = budget_neutral_effect(effect) if recurring_budget_excluded?(recurring, effect)
          category = category_for(recurring, effect)

          rows << {
            recurring_transaction_id: recurring.id,
            account_id: recurring.account_id,
            destination_account_id: recurring.destination_account_id,
            category_id: category&.id,
            date: current,
            name: recurring.merchant&.name || recurring.name,
            amount: converted.amount,
            currency: money_converter.currency,
            native_amount: converted.native_amount,
            native_currency: converted.native_currency,
            recurring_payment_modeled: recurring_payment_modeled?(recurring),
            transfer: effect.fetch(:transfer),
            transaction_kind: effect.fetch(:transaction_kind),
            budget_flow_type: effect.fetch(:budget_flow_type),
            expected_income: effect.fetch(:expected_income),
            expected_spending: effect.fetch(:expected_spending),
            cash_delta: effect.fetch(:cash_delta),
            liquid_delta: effect.fetch(:liquid_delta),
            debt_delta: effect.fetch(:debt_delta),
            portfolio_delta: effect.fetch(:portfolio_delta),
            net_worth_delta: effect.fetch(:net_worth_delta),
            source_snapshot: {
              "id" => recurring.id,
              "name" => recurring.merchant&.name || recurring.name,
              "account_id" => recurring.account_id,
              "destination_account_id" => recurring.destination_account_id,
              "category" => category_snapshot(category),
              "signed_recurring_amount" => amount_for(recurring).to_s,
              "transaction_kind" => effect.fetch(:transaction_kind),
              "effect_label" => effect.fetch(:effect_label, nil),
              "unmodeled_cross_currency_transfer" => unmodeled_cross_currency_recurring_transfer?(recurring),
              "money" => money_converter.snapshot_for(converted)
            },
            risk_flags: converted.risk_flags + effect.fetch(:risk_flags, [])
          }
          current = clamp_day(current.next_month.year, current.next_month.month, recurring.expected_day_of_month)
        end

        rows
      end

      def amount_for(recurring)
        (recurring.expected_amount_avg || recurring.amount).to_d
      end

      def category_for(recurring, effect)
        return nil unless effect.fetch(:budget_flow_type) == "expense"
        return historical_category_for(recurring) || transfer_default_category(effect) if recurring.transfer?

        historical_category_for(recurring)
      end

      def historical_category_for(recurring)
        scope = family.transactions.visible.excluding_pending
          .joins(:entry)
          .where(entries: { account_id: included_account_scope.id_values })
          .where.not(category_id: nil)
          .where.not(kind: Transaction::BUDGET_EXCLUDED_KINDS)
          .where("transactions.investment_activity_label IS NULL OR transactions.investment_activity_label NOT IN (?)", Transaction::INTERNAL_MOVEMENT_LABELS)
          .includes(:entry, :transfer_as_outflow)
        tax_advantaged_ids = family.tax_advantaged_account_ids
        scope = scope.where.not(entries: { account_id: tax_advantaged_ids }) if tax_advantaged_ids.present?

        if recurring.transfer?
          transaction = scope.reverse_chronological.order("entries.id DESC").find do |candidate|
            candidate.entry.account_id == recurring.account_id &&
              candidate.transfer_as_outflow&.to_account&.id == recurring.destination_account_id
          end
        elsif recurring.merchant_id.present?
          transaction = scope.where(merchant_id: recurring.merchant_id).reverse_chronological.order("entries.id DESC").first
        elsif recurring.name.present?
          transaction = scope.where("LOWER(entries.name) = ?", recurring.name.downcase).reverse_chronological.order("entries.id DESC").first
        end

        transaction&.category
      end

      def recurring_budget_excluded?(recurring, effect)
        return false if effect.fetch(:transfer)

        recurring.account_id.present? && family.tax_advantaged_account_ids.include?(recurring.account_id)
      end

      def recurring_effect(recurring, converted, date)
        if unmodeled_cross_currency_recurring_transfer?(recurring)
          return flag_unmodeled_cross_currency_recurring_transfer(
            recurring,
            transfer_classifier.call(
              source_account: recurring.account,
              destination_account: recurring.destination_account,
              amount: 0.to_d,
              destination_amount: 0.to_d,
              date: date
            )
          )
        end

        destination_amount = cross_currency_recurring_transfer?(recurring) ? 0.to_d : nil
        effect = transfer_classifier.call(
          source_account: recurring.account,
          destination_account: recurring.destination_account,
          amount: converted.amount,
          destination_amount: destination_amount,
          date: date
        )
        return effect unless cross_currency_recurring_transfer?(recurring)

        flag_unmodeled_cross_currency_recurring_transfer(recurring, effect)
      end

      def recurring_payment_modeled?(recurring)
        !unmodeled_cross_currency_recurring_transfer?(recurring)
      end

      def unmodeled_cross_currency_recurring_transfer?(recurring)
        cross_currency_recurring_transfer?(recurring) && recurring_destination_in_scope?(recurring)
      end

      def budget_neutral_effect(effect)
        effect.merge(
          budget_flow_type: "none",
          expected_income: 0.to_d,
          expected_spending: 0.to_d
        )
      end

      def flag_unmodeled_cross_currency_recurring_transfer(recurring, effect)
        effect.merge(
          risk_flags: effect.fetch(:risk_flags, []) + [
            {
              "type" => "cross_currency_recurring_transfer_destination_amount_unmodeled",
              "recurring_transaction_id" => recurring.id,
              "source_currency" => recurring.account.currency,
              "destination_currency" => recurring.destination_account.currency,
              "reason" => "recurring transfer stores one amount; create explicit forecast events with destination_amount for precise cross-currency transfer projection"
            }
          ]
        )
      end

      def cross_currency_recurring_transfer?(recurring)
        return false unless recurring.transfer?
        return false if recurring.account&.currency.blank? || recurring.destination_account&.currency.blank?

        recurring.account.currency != recurring.destination_account.currency
      end

      def recurring_destination_in_scope?(recurring)
        recurring.destination_account_id.present? && included_account_scope.id_values.include?(recurring.destination_account_id)
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

      def category_snapshot(category)
        return nil if category.blank?

        {
          "id" => category.id,
          "name" => category.name,
          "parent_id" => category.parent_id,
          "parent_name" => category.parent&.name
        }
      end

      def clamp_day(year, month, day)
        Date.new(year, month, [ day, Date.new(year, month, -1).day ].min)
      end

      def liquidity_classifier
        @liquidity_classifier ||= Forecast::LiquidityClassifier.new(family: family, scenario_ids: scenario_ids)
      end

      def transfer_classifier
        @transfer_classifier ||= Forecast::TransferClassifier.new(
          liquidity_classifier: liquidity_classifier,
          included_account_ids: included_account_scope.id_values
        )
      end
  end
end
