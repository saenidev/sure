require "set"

module Forecast
  class EventEffectBuilder
    def initialize(family:, user:, events:, start_on:, end_on:, money_converter:, scenario_ids:, included_account_ids: nil, accepted_links: [])
      @family = family
      @user = user
      @events = events
      @start_on = start_on
      @end_on = end_on
      @money_converter = money_converter
      @scenario_ids = Array(scenario_ids).compact_blank
      @included_account_ids = included_account_ids
      @accepted_links = accepted_links
    end

    def call
      events.flat_map { |event| expand(event) }
    end

    private
      attr_reader :family, :user, :events, :start_on, :end_on, :money_converter, :scenario_ids, :included_account_ids, :accepted_links

      def expand(event)
        event_dates(event)
          .reject { |date| linked_occurrence?(event, date) }
          .map { |date| payload(event, date) }
      end

      def event_dates(event)
        scenario = event.forecast_scenario
        first_date = [ event.starts_on, scenario&.starts_on, start_on ].compact.max
        last_date = [ event.ends_on || end_on, scenario&.ends_on || end_on, end_on ].compact.min
        return [] if first_date > last_date
        return [] if first_date > end_on || last_date < start_on
        return [ event.starts_on ].select { |date| first_date <= date && date <= last_date } if event.recurrence_rule.blank?

        frequency = event.recurrence_rule.fetch("frequency", "monthly")
        interval = event.recurrence_rule.fetch("interval", 1).to_i.clamp(1, 60)
        day_of_month = event.recurrence_rule.fetch("day_of_month", event.starts_on.day).to_i.clamp(1, 31)
        dates = []
        current = event.starts_on

        while current <= last_date
          dates << current if current >= first_date
          current = case frequency
          when "weekly"
            current + interval.weeks
          else
            next_month = current + interval.months
            clamp_day(next_month.year, next_month.month, day_of_month)
          end
        end

        dates
      end

      def payload(event, date)
        converted = money_converter.convert(amount: event.amount || 0, currency: event.currency, source: "forecast_event:#{event.id}")
        effect = effect_for(event, converted.amount, date)

        {
          forecast_event_id: event.id,
          forecast_scenario_id: event.forecast_scenario_id,
          date: date,
          name: event.name,
          effect_type: event.effect_type,
          category_id: event.category_id,
          account_id: event.account_id,
          destination_account_id: event.destination_account_id,
          amount: converted.amount,
          currency: money_converter.currency,
          native_amount: converted.native_amount,
          native_currency: converted.native_currency,
          transfer: effect.fetch(:transfer),
          transaction_kind: effect.fetch(:transaction_kind),
          budget_flow_type: effect.fetch(:budget_flow_type),
          expected_income: effect.fetch(:expected_income),
          expected_spending: effect.fetch(:expected_spending),
          effect_label: effect.fetch(:effect_label, nil),
          cash_delta: effect.fetch(:cash_delta),
          liquid_delta: effect.fetch(:liquid_delta),
          debt_delta: effect.fetch(:debt_delta),
          portfolio_delta: effect.fetch(:portfolio_delta),
          net_worth_delta: effect.fetch(:net_worth_delta),
          refinance: refinance_metadata_for(event),
          source_snapshot: {
            "id" => event.id,
            "name" => event.name,
            "effect_type" => event.effect_type,
            "behavior" => event.behavior,
            "probability_weight" => event.probability_weight.to_s,
            "account_id" => event.account_id,
            "destination_account_id" => event.destination_account_id,
            "category" => category_snapshot(event.category),
            "date" => date.iso8601,
            "money" => money_converter.snapshot_for(converted),
            "refinance" => refinance_metadata_for(event)
          }.compact,
          risk_flags: converted.risk_flags + effect.fetch(:risk_flags, []) + probability_flags(event)
        }
      end

      def effect_for(event, amount, date)
        case event.effect_type
        when "income"
          standard_effect("income", amount, account: event.account, date: date)
        when "expense"
          standard_effect("expense", amount, account: event.account, date: date)
        when "transfer"
          transfer_classifier.call(source_account: event.account, destination_account: event.destination_account, amount: amount, destination_amount: destination_amount_for(event, date)&.amount, date: date)
        when "debt_drawdown"
          balance_effect(cash_delta: amount, liquid_delta: amount, debt_delta: amount, net_worth_delta: 0.to_d)
        when "debt_payment"
          balance_effect(expected_spending: amount, cash_delta: -amount, liquid_delta: -amount, debt_delta: -amount, net_worth_delta: 0.to_d, transaction_kind: "loan_payment", budget_flow_type: "expense")
        when "debt_interest"
          balance_effect(debt_delta: amount, net_worth_delta: -amount, transaction_kind: "debt_interest", budget_flow_type: "none")
        when "portfolio_contribution"
          balance_effect(expected_spending: amount, cash_delta: -amount, liquid_delta: -amount, portfolio_delta: amount, net_worth_delta: 0.to_d, transaction_kind: "investment_contribution", budget_flow_type: "expense")
        when "portfolio_withdrawal"
          balance_effect(cash_delta: amount, liquid_delta: amount, portfolio_delta: -amount, net_worth_delta: 0.to_d)
        when "market_shock"
          balance_effect(portfolio_delta: amount, net_worth_delta: amount, budget_flow_type: "none")
        when "debt_terms_override"
          # Refinancing assumptions are balance-neutral at the event layer; the debt
          # adapter consumes the refinance metadata to re-rate/re-pay the loan and to
          # apply any cash-out drawdown deterministically from effective_on onward.
          balance_effect(budget_flow_type: "none")
        else
          balance_effect(budget_flow_type: "none")
        end
      end

      def standard_effect(direction, amount, account: nil, date: Date.current)
        signed_amount = direction == "income" ? -amount : amount
        transfer_classifier.call(source_account: account, destination_account: nil, amount: signed_amount, date: date)
      end

      def destination_amount_for(event, date)
        return nil unless event.effect_type == "transfer"
        return nil if event.account.blank? || event.destination_account.blank?
        return nil if event.account.currency == event.destination_account.currency

        money_converter.convert(
          amount: event.source_metadata.fetch("destination_amount"),
          currency: event.source_metadata.fetch("destination_currency"),
          source: "forecast_event:#{event.id}:destination_amount",
          as_of: money_converter.as_of
        )
      end

      def balance_effect(expected_income: 0.to_d, expected_spending: 0.to_d, cash_delta: 0.to_d, liquid_delta: 0.to_d, debt_delta: 0.to_d, portfolio_delta: 0.to_d, net_worth_delta: 0.to_d, transfer: false, transaction_kind: "standard", budget_flow_type: "none", risk_flags: [])
        {
          transfer: transfer,
          transaction_kind: transaction_kind,
          effect_label: transaction_kind == "standard" ? "forecast_event" : transaction_kind,
          budget_flow_type: budget_flow_type,
          expected_income: expected_income,
          expected_spending: expected_spending,
          cash_delta: cash_delta,
          liquid_delta: liquid_delta,
          debt_delta: debt_delta,
          portfolio_delta: portfolio_delta,
          net_worth_delta: net_worth_delta,
          risk_flags: risk_flags
        }
      end

      def transfer_classifier
        @transfer_classifier ||= Forecast::TransferClassifier.new(
          liquidity_classifier: Forecast::LiquidityClassifier.new(family: family, scenario_ids: scenario_ids),
          included_account_ids: included_account_ids
        )
      end

      def clamp_day(year, month, day)
        Date.new(year, month, [ day, Date.new(year, month, -1).day ].min)
      end

      def probability_flags(event)
        return [] if event.probability_weight.to_d == 1.to_d

        [
          {
            "type" => "scenario_probability_not_applied",
            "forecast_event_id" => event.id,
            "probability_weight" => event.probability_weight.to_s,
            "reason" => "foundation keeps scenarios toggleable instead of blending them into baseline"
          }
        ]
      end

      # Surface the scenario-supplied refinance assumptions for debt_terms_override
      # events so the debt adapter can re-rate/re-pay the loan. Returns nil for all
      # other effect types so the baseline stack is never touched.
      def refinance_metadata_for(event)
        return nil unless event.effect_type == "debt_terms_override"

        refinance = event.source_metadata.is_a?(Hash) ? event.source_metadata["refinance"] : nil
        return nil unless refinance.is_a?(Hash)

        {
          "effective_on" => refinance["effective_on"],
          "new_annual_rate" => refinance["new_annual_rate"]&.to_s,
          "new_monthly_payment" => refinance["new_monthly_payment"]&.to_s,
          "new_principal" => refinance["new_principal"]&.to_s,
          "currency" => refinance["currency"]
        }.compact
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

      def linked_occurrence?(event, date)
        accepted_occurrences_by_event_id.fetch(event.id, Set.new).include?(date)
      end

      def accepted_occurrences_by_event_id
        @accepted_occurrences_by_event_id ||= accepted_links.each_with_object(Hash.new { |hash, key| hash[key] = Set.new }) do |link, memo|
          next unless link.status == "accepted"
          next if link.forecast_event_id.blank?

          occurrence_on = link.occurrence_on || link.event_snapshot["occurrence_on"] || link.event_snapshot["starts_on"]
          next if occurrence_on.blank?

          memo[link.forecast_event_id].add(Date.parse(occurrence_on.to_s))
        end
      end
  end
end
