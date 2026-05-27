module Debt
  class ReconciliationService
    def initialize(debt_event)
      @debt_event = debt_event
      @account = debt_event.account
    end

    def call
      return nil unless account.manual_debt_account?
      return accepted_match if accepted_match.present?

      candidates = exact_candidates
      return nil unless candidates.one?

      DebtReconciliationMatch.create!(
        account: account,
        debt_event: debt_event,
        entry: candidates.first,
        match_type: "exact",
        confidence: "high",
        status: "accepted",
        matched_on: Date.current
      )
    end

    private
      attr_reader :debt_event, :account

      def accepted_match
        @accepted_match ||= debt_event.debt_reconciliation_matches.find_by(status: "accepted")
      end

      def exact_candidates
        account.entries
          .excluding_pending
          .where(entryable_type: "Transaction")
          .where(excluded: false)
          .where(date: debt_event.event_date, currency: debt_event.currency, amount: debt_event.amount)
          .where(source: [ nil, "manual" ])
          .where.not(id: accepted_entry_ids)
          .order(:created_at)
          .limit(2)
          .to_a
      end

      def accepted_entry_ids
        DebtReconciliationMatch.where(account: account, status: "accepted").select(:entry_id)
      end
  end
end
