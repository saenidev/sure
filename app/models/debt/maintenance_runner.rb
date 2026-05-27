module Debt
  class MaintenanceRunner
    Result = Data.define(:processed_count, :error_count, :errors)

    def initialize(as_of: Date.current)
      @as_of = as_of
      @errors = []
      @processed_count = 0
    end

    def call
      profiles.find_each do |profile|
        @processed_count += 1
        AccountMaintenanceRunner.new(account: profile.account, as_of: as_of).call
      rescue StandardError => e
        errors << {
          account_id: profile.account_id,
          error_class: e.class.name,
          message: e.message
        }
        Rails.logger.error("[Debt::MaintenanceRunner] account=#{profile.account_id} #{e.class.name}: #{e.message}")
      end

      Result.new(
        processed_count: processed_count,
        error_count: errors.size,
        errors: errors
      )
    end

    private
      attr_reader :as_of, :errors, :processed_count

      def profiles
        DebtProfile
          .includes(:account)
          .where(status: "active")
          .where(
            "auto_accrual_enabled = :enabled OR auto_payment_allocation_enabled = :enabled OR payment_due_day IS NOT NULL",
            enabled: true
          )
      end
  end
end
