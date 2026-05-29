class ForecastGenerationJob < ApplicationJob
  queue_as :medium_priority

  # Generates a baseline forecast for the family off the request path.
  #
  # Forecast::Runner builds 90 days + 36 months + projections, so it must never
  # run inline in the controller. The Runner manages the run group's own status
  # lifecycle (pending -> running -> completed/failed) and, on failure, persists
  # the group with status="failed" and an error_message before re-raising.
  #
  # We rescue that re-raised error here so a failed forecast surfaces to the
  # user as a "failed" run group in the workspace (with a Retry control) rather
  # than as an exploded background job. The error is still logged for operators.
  def perform(family:, user:, name: nil)
    Forecast::Runner.new(
      family: family,
      user: user,
      scenario_stacks: [ [] ],
      run_type: "manual",
      name: name.presence || default_name,
      start_on: Date.current
    ).call
  rescue StandardError => e
    # The Runner has already flipped the group to failed with the message; the
    # workspace failure surface reads that. Swallow so the job does not retry
    # against a now-immutable failed group, but record it for observability.
    Rails.logger.error("ForecastGenerationJob failed for family #{family.id}: #{e.class}: #{e.message}")
    nil
  end

  private
    def default_name
      I18n.t("forecasts.runs.default_name", date: I18n.l(Date.current, format: :long))
    end
end
