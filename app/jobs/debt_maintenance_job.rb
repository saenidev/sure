class DebtMaintenanceJob < ApplicationJob
  queue_as :scheduled
  sidekiq_options lock: :until_executed, on_conflict: :log

  def perform(as_of: Date.current.to_s)
    as_of_date = Date.parse(as_of.to_s)
    result = Debt::MaintenanceRunner.new(as_of: as_of_date).call

    Rails.logger.info(
      "[DebtMaintenanceJob] processed=#{result.processed_count} errors=#{result.error_count} as_of=#{as_of_date}"
    )

    result
  end
end
