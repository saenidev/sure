module Forecast
  class InputBuilder
    Result = Data.define(
      :family,
      :user,
      :currency,
      :periods,
      :scenario_stack,
      :accounts,
      :budgets,
      :recurring_items,
      :pending_entries,
      :portfolio,
      :debt_rows,
      :goals,
      :events,
      :reclassifications,
      :source_data_versions,
      :risk_flags
    ) do
      # reclassifications defaults to an empty stream so existing callers/tests that
      # construct a Result without dated liquidity moves keep their pre-wiring shape.
      def initialize(reclassifications: [], **rest)
        super(reclassifications: reclassifications, **rest)
      end
    end

    def initialize(family:, user:, scenario_ids:, start_on: Date.current, months: 36, daily_days: 90)
      @family = family
      @user = user
      @scenario_ids = Array(scenario_ids).compact_blank
      @start_on = start_on
      @months = months
      @daily_days = daily_days
    end

    def call
      period_result = Forecast::PeriodBuilder.new(family: family, start_on: start_on, months: months, daily_days: daily_days).call
      stack = Forecast::ScenarioStack.new(family: family, scenario_ids: scenario_ids).call
      converter = money_converter
      included_scope = included_account_scope
      recurring_items = Forecast::RecurringExpander.new(
        family: family,
        user: user,
        start_on: start_on,
        end_on: period_result.months.last.end_date,
        money_converter: converter,
        scenario_ids: stack.scenario_ids,
        included_account_scope: included_scope
      ).call
      accepted_links = accepted_event_links_for(stack)
      pending_entries = Forecast::PendingEntryInputBuilder.new(family: family, user: user, start_on: start_on, end_on: period_result.days.last, money_converter: converter, included_account_scope: included_scope, scenario_ids: stack.scenario_ids).call
      linked_future_entries = Forecast::LinkedEntryInputBuilder.new(family: family, user: user, start_on: start_on, end_on: period_result.months.last.end_date, money_converter: converter, included_account_scope: included_scope, accepted_links: accepted_links, scenario_ids: stack.scenario_ids).call
      event_consuming_links = accepted_links_consumed_by_inputs(accepted_links, pending_entries, linked_future_entries, period_result.months.last.end_date)
      events = forecast_events(stack, period_result.months.last.end_date, event_consuming_links)
      accounts = Forecast::AccountsInputBuilder.new(family: family, user: user, money_converter: converter, scenario_ids: stack.scenario_ids, included_account_scope: included_scope).call
      reclassifications = Forecast::LiquidityReclassificationBuilder.new(
        family: family,
        scenario_ids: stack.scenario_ids,
        accounts: accounts,
        periods: period_result,
        run_date: start_on
      ).call

      Result.new(
        family: family,
        user: user,
        currency: family.currency,
        periods: period_result,
        scenario_stack: stack,
        accounts: accounts,
        budgets: Forecast::BudgetInputBuilder.new(family: family, user: user, periods: period_result.months, money_converter: converter, scenario_ids: stack.scenario_ids, included_account_scope: included_scope).call,
        recurring_items: recurring_items,
        pending_entries: (pending_entries + linked_future_entries).sort_by { |row| [ row.fetch(:date), row.fetch(:status), row.fetch(:account_id).to_s, row.fetch(:id).to_s ] },
        portfolio: Forecast::PortfolioSnapshotBuilder.new(family: family, user: user, money_converter: converter).call,
        debt_rows: Forecast::DebtProjectionAdapter.new(family: family, user: user, periods: period_result.months, money_converter: converter, recurring_items: recurring_items, included_account_scope: included_scope, forecast_debt_events: debt_sensitive_events(events), run_date: start_on).call,
        goals: forecast_goals(stack, converter),
        events: events,
        reclassifications: reclassifications,
        source_data_versions: source_data_versions,
        risk_flags: []
      )
    end

    private
      attr_reader :family, :user, :scenario_ids, :start_on, :months, :daily_days

      def forecast_events(stack, end_on, event_consuming_links)
        source_events = family.forecast_events
          .where(status: %w[planned accepted])
          .where(forecast_scenario_id: [ nil, *stack.scenario_ids ])
          .where(
            "(destination_account_id IS NULL AND (account_id IS NULL OR account_id IN (:ids))) OR " \
            "(destination_account_id IS NOT NULL AND (account_id IN (:ids) OR destination_account_id IN (:ids)))",
            ids: included_account_scope.id_values
          )
          .includes(:forecast_scenario, :account, :destination_account, :category)
          .order(:starts_on, :apply_order, :created_at, :id)

        Forecast::EventEffectBuilder.new(
          family: family,
          user: user,
          events: source_events,
          start_on: start_on,
          end_on: end_on,
          money_converter: money_converter,
          scenario_ids: stack.scenario_ids,
          included_account_ids: included_account_scope.id_values,
          accepted_links: event_consuming_links
        ).call
      end

      def accepted_links_consumed_by_inputs(accepted_links, pending_entries, linked_future_entries, horizon_end_on)
        pending_entry_ids = pending_entries.map { |row| row.fetch(:id).to_s }
        pending_transfer_keys = pending_entries.filter_map { |row| row.fetch(:source_snapshot, {}).fetch("transfer_key", nil) }
        linked_future_entry_ids = linked_future_entries.map { |row| row.fetch(:id).to_s }
        linked_future_link_ids = linked_future_entries.filter_map { |row| row.fetch(:source_snapshot, {}).fetch("forecast_event_link_id", nil)&.to_s }

        accepted_links.select do |link|
          if linked_future_link_ids.include?(link.id.to_s)
            true
          elsif link.entry.present?
            accepted_live_entry_consumed?(link.entry, pending_entry_ids, pending_transfer_keys, linked_future_entry_ids, horizon_end_on)
          else
            false
          end
        end
      end

      def accepted_live_entry_consumed?(entry, pending_entry_ids, pending_transfer_keys, linked_future_entry_ids, horizon_end_on)
        return false if entry.excluded?
        return false unless linked_entry_in_scope_for_suppression?(entry)

        if entry.transaction? && entry.transaction.pending?
          pending_entry_ids.include?(entry.id.to_s) || pending_transfer_keys.include?(transfer_key_for(entry.transaction.transfer))
        elsif entry.date > start_on
          entry.date <= horizon_end_on && linked_future_entry_ids.include?(entry.id.to_s)
        else
          true
        end
      end

      def linked_entry_in_scope_for_suppression?(entry)
        transfer = entry.transaction? ? entry.transaction.transfer : nil
        return included_account_scope.id_values.include?(entry.account_id) if transfer.blank?

        source_in_scope = transfer.from_account.present? && included_account_scope.id_values.include?(transfer.from_account.id)
        destination_in_scope = transfer.to_account.present? && included_account_scope.id_values.include?(transfer.to_account.id)
        source_in_scope || destination_in_scope
      end

      def transfer_key_for(transfer)
        return nil if transfer.blank?

        [ transfer.outflow_transaction_id, transfer.inflow_transaction_id ].compact.map(&:to_s).sort.join(":")
      end

      def accepted_event_links_for(stack)
        @accepted_event_links_by_stack_key ||= {}
        @accepted_event_links_by_stack_key[stack.key] ||= family.forecast_event_links
          .where(status: "accepted")
          .includes(:entry, :forecast_event)
          .order(:forecast_event_id, :occurrence_on, :entry_id, :id)
          .to_a
          .select { |link| accepted_link_in_stack?(link, stack) }
      end

      def accepted_link_in_stack?(link, stack)
        if link.forecast_event.present?
          return [ nil, *stack.scenario_ids ].include?(link.forecast_event.forecast_scenario_id)
        end

        scenario_id = link.event_snapshot&.fetch("forecast_scenario_id", nil)
        scenario_id.blank? || stack.scenario_ids.map(&:to_s).include?(scenario_id.to_s)
      end

      def debt_sensitive_events(events)
        events.select { |row| row.fetch(:effect_type, nil).in?(%w[debt_drawdown debt_payment debt_interest debt_terms_override]) || row.fetch(:transaction_kind, nil).in?(%w[loan_payment debt_interest]) }
      end

      def forecast_goals(stack, converter)
        family.forecast_goals
          .where(status: "active")
          .where(forecast_scenario_id: [ nil, *stack.scenario_ids ])
          .includes(:forecast_scenario)
          .order(:target_date, :goal_type, :name, :id)
          .map { |goal| goal_payload(goal, converter) }
      end

      def goal_payload(goal, converter)
        payload = goal.attributes.merge(
          "evaluation_starts_on" => goal_evaluation_starts_on(goal)&.iso8601,
          "evaluation_ends_on" => goal_evaluation_ends_on(goal)&.iso8601,
          "forecast_scenario" => scenario_snapshot(goal.forecast_scenario)
        )
        return payload if goal.target_amount.blank?

        converted = converter.convert(
          amount: goal.target_amount,
          currency: goal.currency,
          source: "forecast_goal:#{goal.id}:target_amount"
        )

        payload.merge(
          "target_amount" => converted.amount,
          "currency" => converter.currency,
          "target_money_snapshot" => converter.snapshot_for(converted),
          "risk_flags" => converted.risk_flags
        )
      end

      def goal_evaluation_starts_on(goal)
        return goal.starts_on if goal.starts_on.present?
        return goal.target_date if goal.target_date.present?
        return goal.forecast_scenario.starts_on if goal.forecast_scenario.present? && goal.forecast_scenario.starts_on.present?

        start_on
      end

      def goal_evaluation_ends_on(goal)
        return goal.ends_on if goal.ends_on.present?
        return goal.target_date if goal.target_date.present?
        return goal.forecast_scenario.ends_on if goal.forecast_scenario.present? && goal.forecast_scenario.ends_on.present?

        nil
      end

      def scenario_snapshot(scenario)
        return nil if scenario.blank?

        {
          "id" => scenario.id,
          "name" => scenario.name,
          "starts_on" => scenario.starts_on&.iso8601,
          "ends_on" => scenario.ends_on&.iso8601
        }
      end

      def source_data_versions
        included_ids = included_account_scope.ids
        security_ids = Holding.where(account_id: included_ids).distinct.select(:security_id)

        {
          "accounts_max_updated_at" => family.accounts.where(id: included_ids).maximum(:updated_at)&.iso8601,
          "entries_max_updated_at" => family.entries.where(account_id: included_ids).maximum(:updated_at)&.iso8601,
          "budgets_max_updated_at" => Budget.where(family: family).maximum(:updated_at)&.iso8601,
          "forecast_budget_overrides_max_updated_at" => family.forecast_budget_overrides.maximum(:updated_at)&.iso8601,
          "recurring_transactions_max_updated_at" => scoped_recurring_transactions.maximum(:updated_at)&.iso8601,
          "forecast_scenarios_max_updated_at" => family.forecast_scenarios.maximum(:updated_at)&.iso8601,
          "forecast_events_max_updated_at" => scoped_forecast_events.maximum(:updated_at)&.iso8601,
          "forecast_event_links_max_updated_at" => family.forecast_event_links.maximum(:updated_at)&.iso8601,
          "forecast_goals_max_updated_at" => family.forecast_goals.maximum(:updated_at)&.iso8601,
          "forecast_account_liquidity_settings_max_updated_at" => family.forecast_account_liquidity_settings.where(account_id: included_ids).maximum(:updated_at)&.iso8601,
          "debt_profiles_max_updated_at" => DebtProfile.joins(:account).where(accounts: { id: included_ids }).maximum(:updated_at)&.iso8601,
          "debt_rate_periods_max_updated_at" => DebtRatePeriod.joins(debt_profile: :account).where(accounts: { id: included_ids }).maximum(:updated_at)&.iso8601,
          "debt_obligations_max_updated_at" => DebtObligation.where(account_id: included_ids).maximum(:updated_at)&.iso8601,
          "debt_payment_allocations_max_updated_at" => DebtPaymentAllocation.where(account_id: included_ids).maximum(:updated_at)&.iso8601,
          "holdings_max_updated_at" => Holding.where(account_id: included_ids).maximum(:updated_at)&.iso8601,
          "security_prices_max_updated_at" => Security::Price.where(security_id: security_ids).maximum(:updated_at)&.iso8601,
          "exchange_rates_max_updated_at" => ExchangeRate.maximum(:updated_at)&.iso8601
        }
      end

      def money_converter
        @money_converter ||= Forecast::MoneyConverter.new(family: family, as_of: start_on)
      end

      def included_account_scope
        @included_account_scope ||= Forecast::IncludedAccountScope.new(family: family, user: user)
      end

      def scoped_recurring_transactions
        family.recurring_transactions.where(
          "(destination_account_id IS NULL AND (account_id IS NULL OR account_id IN (:ids))) OR " \
          "(destination_account_id IS NOT NULL AND (account_id IN (:ids) OR destination_account_id IN (:ids)))",
          ids: included_account_scope.id_values
        )
      end

      def scoped_forecast_events
        family.forecast_events.where(
          "(destination_account_id IS NULL AND (account_id IS NULL OR account_id IN (:ids))) OR " \
          "(destination_account_id IS NOT NULL AND (account_id IN (:ids) OR destination_account_id IN (:ids)))",
          ids: included_account_scope.id_values
        )
      end
  end
end
