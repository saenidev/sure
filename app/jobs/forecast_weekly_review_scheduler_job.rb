# Lightweight fan-out enqueuer for the weekly forecast review cadence.
#
# Runs from a single sidekiq-cron entry (see config/schedule.yml) and enqueues
# ONE ForecastWeeklyReviewJob per eligible family. Doing the fan-out here (one
# tiny enqueue per family) instead of iterating + running the Runner inline
# keeps each unit of work bounded to a single family so a large instance never
# loads every family's forecast inputs into one process (RAM safety).
#
# Eligibility (forecasting preview enabled + at least one account/scenario) is
# evaluated on the Family model so the rule lives in one place and the job stays
# skinny.
class ForecastWeeklyReviewSchedulerJob < ApplicationJob
  queue_as :scheduled
  sidekiq_options lock: :until_executed, on_conflict: :log

  def perform
    Rails.logger.info("[ForecastWeeklyReviewScheduler] Fanning out weekly forecast reviews")

    count = 0
    Family.scheduled_forecast_eligible_ids.each do |family_id|
      ForecastWeeklyReviewJob.perform_later(family_id)
      count += 1
    end

    Rails.logger.info("[ForecastWeeklyReviewScheduler] Enqueued #{count} weekly forecast review(s)")
  end
end
