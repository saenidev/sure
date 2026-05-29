# Lightweight fan-out enqueuer for the market-close forecast trigger.
#
# Runs from a single sidekiq-cron entry shortly after ImportMarketDataJob (see
# config/schedule.yml) and enqueues ONE ForecastMarketCloseJob per eligible
# family. As with the weekly scheduler, the fan-out keeps each unit of work
# bounded to a single family (RAM safety) and isolates failures: one bad family
# never aborts the batch because each runs in its own job.
class ForecastMarketCloseSchedulerJob < ApplicationJob
  queue_as :scheduled
  sidekiq_options lock: :until_executed, on_conflict: :log

  def perform
    Rails.logger.info("[ForecastMarketCloseScheduler] Fanning out market-close forecast triggers")

    count = 0
    Family.scheduled_forecast_eligible_ids.each do |family_id|
      ForecastMarketCloseJob.perform_later(family_id)
      count += 1
    end

    Rails.logger.info("[ForecastMarketCloseScheduler] Enqueued #{count} market-close trigger(s)")
  end
end
