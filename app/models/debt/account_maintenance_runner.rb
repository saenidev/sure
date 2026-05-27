module Debt
  class AccountMaintenanceRunner
    Result = Data.define(
      :account_id,
      :interest_event_id,
      :obligation_id,
      :allocation_ids,
      :skipped_reason
    )

    def initialize(account:, as_of: Date.current)
      @account = account
      @as_of = as_of
    end

    def call
      return skipped("inactive_or_unsupported") unless account.manual_debt_account? && profile&.active?
      if profile.effective_start_on.present? && profile.effective_start_on > as_of
        return skipped("not_effective")
      end

      interest_event = InterestAccrualService.new(account: account, as_of: as_of).call
      obligation = ObligationService.new(account: account, as_of: as_of).generate_next
      allocations = allocate_payments

      Result.new(
        account_id: account.id,
        interest_event_id: interest_event&.id,
        obligation_id: obligation&.id,
        allocation_ids: allocations.map(&:id),
        skipped_reason: nil
      )
    end

    private
      attr_reader :account, :as_of

      def profile
        @profile ||= account.debt_profile
      end

      def skipped(reason)
        Result.new(
          account_id: account.id,
          interest_event_id: nil,
          obligation_id: nil,
          allocation_ids: [],
          skipped_reason: reason
        )
      end

      def allocate_payments
        return [] unless profile.auto_payment_allocation_enabled?

        candidate_payment_entries.filter_map do |entry|
          PaymentAllocationService.new(entry: entry).call
        end
      end

      def candidate_payment_entries
        scope = account.entries
          .where(entryable_type: "Transaction")
          .where("entries.amount < 0")
          .where("entries.date <= ?", as_of)
          .where(excluded: false)
          .where(source: [ nil, "manual" ])
          .where.not(id: DebtPaymentAllocation.where(account: account).select(:entry_id))
          .order(:date, :created_at)

        scope = scope.where("entries.date >= ?", profile.effective_start_on) if profile.effective_start_on.present?
        scope
      end
  end
end
