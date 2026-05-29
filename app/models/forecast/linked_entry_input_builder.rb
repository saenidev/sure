module Forecast
  class LinkedEntryInputBuilder < PendingEntryInputBuilder
    MissingSnapshotTransferEndpoint = Class.new(StandardError)

    def initialize(family:, user:, start_on:, end_on:, money_converter:, included_account_scope:, accepted_links:, scenario_ids: [])
      super(family: family, user: user, start_on: start_on, end_on: end_on, money_converter: money_converter, included_account_scope: included_account_scope, scenario_ids: scenario_ids)
      @accepted_links = accepted_links
    end

    def call
      accepted_links
        .sort_by { |link| [ link.occurrence_on || Date.new(9999, 12, 31), link.forecast_event_id.to_s, link.entry_id.to_s, link.id.to_s ] }
        .filter_map do |link|
          entry = link.entry
          if entry.blank?
            next snapshot_payload(link)
          end
          next if entry_pending?(entry)
          next if entry.excluded?
          next unless start_on <= entry.date && entry.date <= end_on
          next unless entry.date > start_on
          next unless linked_entry_in_scope?(entry)

          payload(entry, status: "linked_future", link: link)
        end
    end

    private
      attr_reader :accepted_links

      def snapshot_payload(link)
        snapshot = link.entry_snapshot || {}
        date = Date.parse(snapshot.fetch("date"))
        return nil unless start_on <= date && date <= end_on
        return nil unless date > start_on
        return nil unless snapshot_in_scope?(link, snapshot)

        source_amount = (snapshot["transfer_source_amount"].presence || snapshot.fetch("amount").to_d.abs).to_d
        source_currency = snapshot["transfer_source_currency"].presence || snapshot.fetch("currency", money_converter.currency)
        converted = money_converter.convert(
          amount: source_amount,
          currency: source_currency,
          source: "forecast_event_link:#{link.id}:entry_snapshot",
          as_of: snapshot_source_date(snapshot, date)
        )
        destination_amount = snapshot_destination_amount(link, snapshot, date)
        effect = snapshot_effect(link, snapshot, converted.amount, date, destination_amount: destination_amount&.fetch(:amount))
        category = category_from_snapshot(snapshot["category"])

        {
          id: snapshot.fetch("id"),
          account_id: snapshot.fetch("account_id"),
          destination_account_id: effect.fetch(:destination_account_id, nil),
          date: date,
          name: snapshot.fetch("name"),
          amount: converted.amount,
          currency: money_converter.currency,
          native_amount: converted.native_amount,
          native_currency: converted.native_currency,
          direction: effect.fetch(:direction),
          status: "linked_future",
          transaction_kind: effect.fetch(:transaction_kind),
          budget_flow_type: effect.fetch(:budget_flow_type),
          category_id: category&.id,
          expected_income: effect.fetch(:expected_income),
          expected_spending: effect.fetch(:expected_spending),
          pending_income: 0.to_d,
          pending_spending: 0.to_d,
          cash_delta: effect.fetch(:cash_delta),
          liquid_delta: effect.fetch(:liquid_delta),
          debt_delta: effect.fetch(:debt_delta),
          portfolio_delta: effect.fetch(:portfolio_delta),
          net_worth_delta: effect.fetch(:net_worth_delta),
          source_snapshot: snapshot.merge(
            "source" => "deleted_entry_snapshot",
            "forecast_event_link_id" => link.id,
            "forecast_event_id" => link.forecast_event_id,
            "forecast_event_occurrence_on" => link.occurrence_on&.iso8601,
            "category" => category_snapshot(category) || snapshot["category"],
            "money" => money_converter.snapshot_for(converted),
            "destination_money" => destination_amount ? money_converter.snapshot_for(destination_amount.fetch(:converted)) : {}
          ),
          risk_flags: converted.risk_flags + Array(destination_amount&.fetch(:risk_flags)) + effect.fetch(:risk_flags, []) + [
            {
              "type" => "linked_entry_reference_deleted",
              "forecast_event_link_id" => link.id,
              "entry_snapshot_id" => snapshot.fetch("id")
            }
          ]
        }
      end

      def snapshot_in_scope?(link, snapshot)
        account_ids = [
          snapshot.fetch("account_id", nil),
          snapshot.fetch("transfer_source_account_id", nil),
          snapshot.fetch("transfer_destination_account_id", nil),
          link.event_snapshot&.fetch("account_id", nil),
          link.event_snapshot&.fetch("destination_account_id", nil)
        ].compact.map(&:to_s)
        account_ids.any? { |account_id| included_account_scope.id_values.map(&:to_s).include?(account_id) }
      end

      def snapshot_effect(link, snapshot, amount, date, destination_amount: nil)
        account = family.accounts.find_by(id: snapshot.fetch("transfer_source_account_id", snapshot.fetch("account_id")))
        destination_account = family.accounts.find_by(id: snapshot.fetch("transfer_destination_account_id", link.event_snapshot&.fetch("destination_account_id", nil)))
        if cross_currency_snapshot_transfer?(snapshot, account, destination_account) && destination_amount.blank?
          raise MissingSnapshotTransferEndpoint, "Deleted linked transfer snapshot #{link.id} is missing destination amount/currency for cross-currency transfer"
        end

        signed_amount = signed_snapshot_amount(snapshot, amount, destination_account)
        effect = transfer_classifier.call(source_account: account, destination_account: destination_account, amount: signed_amount, destination_amount: destination_amount, date: date)
        kind = snapshot_transaction_kind(snapshot, effect)
        budget_forced_expense = kind.in?(%w[investment_contribution loan_payment])
        budget_excluded = Transaction::BUDGET_EXCLUDED_KINDS.include?(kind) || budget_scope_excluded_account?(account)
        budget_flow_type = if effect.fetch(:budget_flow_type) == "none" || budget_excluded
          "none"
        elsif budget_forced_expense
          "expense"
        else
          signed_amount.negative? ? "income" : "expense"
        end
        direction = case budget_flow_type
        when "expense" then "spending"
        when "income" then "income"
        else
          effect.fetch(:debt_delta, 0).to_d.negative? ? "debt_payment" : "transfer"
        end

        effect.merge(
          transaction_kind: kind,
          direction: direction,
          destination_account_id: destination_account&.id,
          budget_flow_type: budget_flow_type,
          expected_income: budget_flow_type == "income" ? amount : 0.to_d,
          expected_spending: budget_flow_type == "expense" ? amount : 0.to_d
        )
      end

      def snapshot_destination_amount(link, snapshot, date)
        amount = snapshot.fetch("transfer_destination_amount", nil)
        currency = snapshot.fetch("transfer_destination_currency", nil)
        return nil if amount.blank? || currency.blank?

        converted = money_converter.convert(
          amount: amount,
          currency: currency,
          source: "forecast_event_link:#{link.id}:entry_snapshot_destination",
          as_of: snapshot_destination_date(snapshot, date)
        )

        { amount: converted.amount, converted: converted, risk_flags: converted.risk_flags }
      end

      def cross_currency_snapshot_transfer?(snapshot, account, destination_account)
        return false if destination_account.blank?

        source_currency = snapshot["transfer_source_currency"].presence || snapshot["currency"].presence || account&.currency
        destination_currency = snapshot["transfer_destination_currency"].presence || destination_account.currency
        source_currency.present? && destination_currency.present? && source_currency != destination_currency
      end

      def signed_snapshot_amount(snapshot, converted_source_amount, destination_account)
        return converted_source_amount.to_d if destination_account.present?

        snapshot.fetch("amount").to_d.negative? ? -converted_source_amount.to_d : converted_source_amount.to_d
      end

      def snapshot_transaction_kind(snapshot, effect)
        return effect.fetch(:transaction_kind) if effect.fetch(:transfer)

        snapshot.fetch("transaction_kind", "standard")
      end

      def snapshot_source_date(snapshot, fallback_date)
        Date.parse((snapshot["transfer_source_date"].presence || snapshot["date"] || fallback_date).to_s)
      end

      def snapshot_destination_date(snapshot, fallback_date)
        Date.parse((snapshot["transfer_destination_date"].presence || snapshot["date"] || fallback_date).to_s)
      end

      def category_from_snapshot(snapshot)
        return nil if snapshot.blank?

        family.categories.find_by(id: snapshot["id"])
      end

      def entry_pending?(entry)
        entry.transaction? && entry.transaction.pending?
      end

      def linked_entry_in_scope?(entry)
        transfer = transfer_for(entry)
        return included_account_scope.id_values.include?(entry.account_id) if transfer.blank?

        source_in_scope = transfer.from_account.present? && included_account_scope.id_values.include?(transfer.from_account.id)
        destination_in_scope = transfer.to_account.present? && included_account_scope.id_values.include?(transfer.to_account.id)
        source_in_scope || destination_in_scope
      end
  end
end
