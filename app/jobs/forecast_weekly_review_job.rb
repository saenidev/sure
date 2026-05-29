# Generates the weekly forecast review for a SINGLE family.
#
# Enqueued one-per-family by ForecastWeeklyReviewSchedulerJob so each invocation
# is bounded to one family's inputs (RAM safety). It:
#   - re-checks eligibility (preview enabled + projectable) at run time, since
#     the family's state may have changed since the scheduler fanned out;
#   - stays idempotent: skips when a same-day weekly group already exists;
#   - runs Forecast::Runner with run_type "weekly" and scenario_stacks =
#     baseline plus any active comparison stack the family has configured (the
#     Runner creates the draft ForecastReview shell);
#   - rescues a Runner failure so the failed group is persisted with an
#     error_message (the Runner does that before re-raising) and the failure is
#     logged — one bad family must never abort the batch (each family runs in
#     its own job).
class ForecastWeeklyReviewJob < ApplicationJob
  queue_as :scheduled

  def perform(family_id)
    family = Family.find_by(id: family_id)
    return if family.nil?

    unless family.eligible_for_scheduled_forecast?
      Rails.logger.info("[ForecastWeeklyReview] Skipping ineligible family #{family_id}")
      return
    end

    if family.scheduled_forecast_group_exists?(run_type: "weekly")
      Rails.logger.info("[ForecastWeeklyReview] Skipping family #{family_id}; weekly group already exists today")
      return
    end

    author = family.scheduled_forecast_author
    if author.nil?
      Rails.logger.info("[ForecastWeeklyReview] Skipping family #{family_id}; no preview-enabled author")
      return
    end

    Forecast::Runner.new(
      family: family,
      user: author,
      scenario_stacks: scenario_stacks_for(family),
      run_type: "weekly",
      name: I18n.t("forecasts.runs.weekly_name", date: I18n.l(Date.current, format: :long)),
      trigger_metadata: { "trigger" => "weekly_review", "scheduled_on" => Date.current.iso8601 }
    ).call
  rescue StandardError => e
    # The Runner has already flipped the group to failed with the message; we
    # swallow here so one family's failure never aborts the batch. Other
    # families run in their own jobs and are unaffected.
    Rails.logger.error("[ForecastWeeklyReview] Failed for family #{family_id}: #{e.class}: #{e.message}")
    nil
  end

  private
    # Baseline (`[]`) is always included as the headline projection. When the
    # family has active scenarios, add a single combined comparison stack of all
    # active scenario ids so the weekly review surfaces the family's configured
    # planning alongside the baseline without fanning out a run per scenario.
    def scenario_stacks_for(family)
      active_ids = family.forecast_scenarios.active.ordered.pluck(:id)
      stacks = [ [] ]
      stacks << active_ids if active_ids.any?
      stacks
    end
end
