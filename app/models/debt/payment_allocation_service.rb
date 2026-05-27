module Debt
  class PaymentAllocationService
    def initialize(entry:)
      @entry = entry
      @account = entry.account
    end

    def call
      return nil unless eligible?
      return existing_allocation if existing_allocation.present?

      obligation = next_obligation
      amounts = allocate_amounts(obligation)
      allocation = DebtPaymentAllocation.create!(
        account: account,
        entry: entry,
        debt_profile: profile,
        debt_obligation: obligation,
        allocation_method: "automatic",
        status: allocation_status(obligation),
        principal_amount: amounts[:principal],
        interest_amount: amounts[:interest],
        fee_amount: amounts[:fee],
        unapplied_amount: amounts[:unapplied],
        currency: entry.currency,
        source: "sure",
        external_id: "debt-allocation-#{entry.id}"
      )

      update_obligation!(obligation, allocation) if obligation.present?
      allocation
    end

    private
      attr_reader :entry, :account

      def profile
        @profile ||= account.debt_profile
      end

      def eligible?
        account.manual_debt_account? &&
          profile&.active? &&
          profile.auto_payment_allocation_enabled? &&
          entry.transaction? &&
          entry.amount.negative? &&
          !entry.transaction.pending? &&
          safe_payment_source?
      end

      def existing_allocation
        @existing_allocation ||= DebtPaymentAllocation.find_by(entry: entry)
      end

      def safe_payment_source?
        return false unless entry.source.blank? || entry.source == "manual"
        return true unless entry.transaction.transfer_as_inflow.present?

        transfer_inflow_to_account?
      end

      def transfer_inflow_to_account?
        transfer = entry.transaction.transfer_as_inflow

        transfer&.confirmed? && transfer.to_account == account
      end

      def next_obligation
        account.debt_obligations
          .where(status: %w[open partially_paid overdue])
          .where("due_on >= ?", entry.date)
          .order(:due_on)
          .first ||
          account.debt_obligations
            .where(status: %w[open partially_paid overdue])
            .order(:due_on)
            .first
      end

      def allocate_amounts(obligation)
        remaining = entry.amount.abs
        fee = take_from(remaining, outstanding_component(obligation, :fee_amount))
        remaining -= fee
        interest = take_from(remaining, outstanding_component(obligation, :interest_amount))
        remaining -= interest
        scheduled_principal = obligation.present? ? take_from(remaining, outstanding_component(obligation, :principal_amount)) : remaining
        remaining -= scheduled_principal
        extra_principal = obligation.present? ? remaining : 0.to_d
        remaining -= extra_principal
        principal = scheduled_principal + extra_principal

        {
          fee: fee,
          interest: interest,
          principal: principal,
          unapplied: remaining
        }
      end

      def take_from(available, requested)
        [ available, requested ].min
      end

      def outstanding_component(obligation, component)
        return 0.to_d if obligation.blank?

        due_field = :"#{component.to_s.sub("_amount", "")}_due_amount"
        total_due = obligation.public_send(due_field) || 0
        allocated = obligation.debt_payment_allocations.where.not(status: "voided").sum(component)
        [ total_due.to_d - allocated.to_d, 0.to_d ].max
      end

      def allocation_status(obligation)
        return "estimated" if obligation.blank?
        return "needs_review" if entry.amount.abs < remaining_due(obligation)

        "allocated"
      end

      def remaining_due(obligation)
        [ obligation.amount_due.to_d - obligation.paid_amount.to_d, 0.to_d ].max
      end

      def update_obligation!(obligation, allocation)
        paid_amount = [ allocation.component_total - allocation.unapplied_amount, remaining_due(obligation) ].min
        new_paid_amount = obligation.paid_amount.to_d + paid_amount
        new_status = new_paid_amount >= obligation.amount_due.to_d ? "paid" : "partially_paid"

        obligation.update!(paid_amount: new_paid_amount, status: new_status)
      end
  end
end
