# Market-close forecast trigger for a SINGLE family.
#
# Runs after market data has been imported (chained or via a slightly-later cron
# entry; see config/schedule.yml). Its job is to surface a forecast for human
# (or later Hermes) review ONLY when the market move was material — generating a
# fresh group every market close would be noise.
#
# Flow per family (bounded to one family for RAM safety):
#   - re-check eligibility (preview enabled + projectable);
#   - stay idempotent: skip when a same-day market_close group already exists;
#   - generate a fresh baseline group with run_type "market_close";
#   - compare it to the family's previous completed group via
#     Forecast::MaterialMovement;
#   - if material: annotate the draft ForecastReview with the trigger reason +
#     flags so a human reviews it;
#   - if immaterial: discard the just-generated group by marking it "discarded"
#     (a durable terminal marker, bypassing the completed-output immutability
#     guard) so the cadence leaves no review noise yet a second same-day tick is
#     still suppressed instead of wastefully re-running.
#
# A Runner failure is rescued and logged so one family's failure never aborts
# the batch; the Runner persists the failed group + error_message before
# re-raising, so the failure is still observable.
class ForecastMarketCloseJob < ApplicationJob
  queue_as :scheduled

  def perform(family_id)
    family = Family.find_by(id: family_id)
    return if family.nil?

    unless family.eligible_for_scheduled_forecast?
      Rails.logger.info("[ForecastMarketClose] Skipping ineligible family #{family_id}")
      return
    end

    if family.scheduled_forecast_group_exists?(run_type: "market_close")
      Rails.logger.info("[ForecastMarketClose] Skipping family #{family_id}; market_close group already exists today")
      return
    end

    author = family.scheduled_forecast_author
    if author.nil?
      Rails.logger.info("[ForecastMarketClose] Skipping family #{family_id}; no preview-enabled author")
      return
    end

    previous_group = family.latest_completed_forecast_group

    group = Forecast::Runner.new(
      family: family,
      user: author,
      scenario_stacks: [ [] ],
      run_type: "market_close",
      name: I18n.t("forecasts.runs.market_close_name", date: I18n.l(Date.current, format: :long)),
      trigger_metadata: { "trigger" => "market_close", "scheduled_on" => Date.current.iso8601 }
    ).call

    evaluate_movement!(family, group, previous_group)
  rescue StandardError => e
    Rails.logger.error("[ForecastMarketClose] Failed for family #{family_id}: #{e.class}: #{e.message}")
    nil
  end

  private
    def evaluate_movement!(family, group, previous_group)
      result = Forecast::MaterialMovement.new(
        current_group: group,
        previous_group: previous_group
      ).call

      if result.material?
        group.forecast_review&.flag_triggered!(
          reason: "material_market_movement",
          flags: result.reasons,
          metrics: result.metrics
        )
        Rails.logger.info("[ForecastMarketClose] Material movement for family #{family.id}: #{result.reasons.join(', ')}")
      else
        discard_group!(group)
        Rails.logger.info("[ForecastMarketClose] Immaterial movement for family #{family.id}; discarded group #{group.id}")
      end
    end

    # Mark the just-generated group "discarded" instead of deleting it. The
    # discarded status is a durable, terminal marker the same-day idempotency
    # guard (Family#scheduled_forecast_group_exists?) recognizes as "already
    # processed today", so a SECOND quiet-day tick is suppressed and never
    # re-runs the Runner + MaterialMovement. We write the status column directly
    # to bypass the completed-output immutability guard (the group is already
    # "completed" here) without touching the rest of the persisted output, so the
    # marker stays cheap and the immutable forecast days/months are untouched.
    def discard_group!(group)
      group.update_columns(status: "discarded", updated_at: Time.current)
    end
end
