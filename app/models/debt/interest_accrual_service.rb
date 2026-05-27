module Debt
  class InterestAccrualService
    SOURCE = "sure"

    def initialize(account:, as_of: Date.current)
      @account = account
      @as_of = as_of
      @posting_run = nil
    end

    def call
      return nil unless eligible?
      return completed_event if completed_event.present?

      period_start = next_period_start
      return nil if period_start > as_of

      terms = AccountTerms.new(account, as_of: as_of).resolve
      return nil unless terms.accrual_ready?

      amount = accrued_amount(terms, period_start)
      return nil unless amount.positive?

      create_posting_run(period_start)

      event = nil
      ApplicationRecord.transaction do
        event = pending_event || create_event!(amount, period_start)
        event.assign_attributes(event_attributes(amount, period_start).except(:idempotency_key)) if event.status == "pending"
        event.save! if event.changed?

        match = ReconciliationService.new(event).call

        if match.present?
          event.reload
        else
          entry = create_interest_entry!(event)
          event.update!(entry: entry, status: "posted")
          entry.sync_account_later
        end

        profile.update!(last_accrued_on: as_of)
      end

      posting_run.update!(status: "succeeded", finished_at: Time.current)
      event
    rescue StandardError => e
      posting_run&.update!(
        status: "failed",
        finished_at: Time.current,
        error_class: e.class.name,
        error_message: e.message
      )
      raise
    end

    private
      attr_reader :account, :as_of, :posting_run

      def profile
        @profile ||= account.debt_profile
      end

      def eligible?
        account.manual_debt_account? &&
          profile&.active? &&
          profile.auto_accrual_enabled?
      end

      def completed_event
        @completed_event ||= events_for_period
          .where(status: %w[posted matched])
          .order(created_at: :desc)
          .first
      end

      def pending_event
        @pending_event ||= events_for_period
          .where(status: "pending")
          .order(created_at: :desc)
          .first
      end

      def events_for_period
        account.debt_events.where(event_type: "interest_accrual", period_end_on: as_of)
      end

      def next_period_start
        profile.last_accrued_on ? profile.last_accrued_on.next_day : as_of
      end

      def accrued_amount(terms, period_start)
        days = (as_of - period_start).to_i + 1
        (terms.opening_balance * (terms.annual_rate / 100) / 365 * days).round(4)
      end

      def create_posting_run(period_start)
        @posting_run = account.debt_posting_runs.create!(
          debt_profile: profile,
          run_type: "interest_accrual",
          period_start_on: period_start,
          period_end_on: as_of,
          status: "started",
          started_at: Time.current
        )
      end

      def create_event!(amount, period_start)
        account.debt_events.create!(event_attributes(amount, period_start))
      end

      def event_attributes(amount, period_start)
        {
          debt_profile: profile,
          event_type: "interest_accrual",
          status: "pending",
          event_date: as_of,
          period_start_on: period_start,
          period_end_on: as_of,
          amount: amount,
          currency: account.currency,
          source: SOURCE,
          idempotency_key: idempotency_key_for(period_start),
          extra: {
            "calculation" => "simple_daily",
            "annual_rate" => AccountTerms.new(account, as_of: as_of).resolve.annual_rate.to_s
          }
        }
      end

      def idempotency_key_for(period_start)
        base_key = "interest_accrual:#{period_start}:#{as_of}"
        return base_key unless account.debt_events.where(idempotency_key: base_key).exists?

        retry_number = events_for_period.count + 1
        "#{base_key}:retry:#{retry_number}"
      end

      def create_interest_entry!(event)
        account.entries.create!(
          date: event.event_date,
          name: "Interest accrued",
          amount: event.amount,
          currency: event.currency,
          source: SOURCE,
          external_id: "debt-interest-#{event.id}",
          user_modified: true,
          import_locked: true,
          entryable: Transaction.new(
            kind: "standard",
            extra: {
              "sure" => {
                "debt_event_id" => event.id,
                "event_type" => event.event_type
              }
            }
          )
        )
      end
  end
end
