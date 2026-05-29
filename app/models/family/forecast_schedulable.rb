module Family::ForecastSchedulable
  extend ActiveSupport::Concern

  # Eligibility + idempotency rules for the scheduled forecast jobs
  # (ForecastWeeklyReviewJob / ForecastMarketCloseJob). Kept on the model so the
  # jobs stay skinny and the rules are testable in isolation.

  class_methods do
    # Families that should receive scheduled forecast runs. A family is eligible
    # when forecasting preview is enabled for it (at least one of its users has
    # opted into preview features) AND it has at least one account or scenario to
    # project. The scheduler fans out one enqueue per id so each job is bounded
    # to a single family.
    #
    # Returns the family ids (not loaded records) to keep the fan-out
    # lightweight and avoid materializing every family in memory.
    def scheduled_forecast_eligible_ids
      where(
        id: User.where(id: User.with_preview_features.select(:id)).select(:family_id)
      ).select(:id).find_each.filter_map do |family|
        family.id if family.eligible_for_scheduled_forecast?
      end
    end
  end

  # True when forecasting preview is enabled for this family, i.e. at least one
  # member has opted into preview features. Scoped to this family's users only.
  def forecasting_preview_enabled?
    users.with_preview_features.exists?
  end

  # The family must have something to project: at least one account OR at least
  # one scenario. A brand-new family with neither is skipped (no group created).
  def forecast_projectable?
    accounts.visible.exists? || forecast_scenarios.exists?
  end

  def eligible_for_scheduled_forecast?
    forecasting_preview_enabled? && forecast_projectable?
  end

  # True when a completed-or-in-flight run group of `run_type` already exists for
  # `on` (defaults to today). Used by the scheduled jobs to stay idempotent-ish:
  # a second tick on the same day must not stack a duplicate group. Failed groups
  # do NOT count, so a retry after a failure is allowed.
  def scheduled_forecast_group_exists?(run_type:, on: Date.current)
    forecast_run_groups
      .where(run_type: run_type)
      .where(status: %w[pending running completed])
      .where(created_at: on.all_day)
      .exists?
  end

  # The most recent COMPLETED run group, eager-loading its runs + days so a
  # MaterialMovement comparison reads them without N+1. Optionally excludes a
  # group (the just-generated one) so the market-close job can fetch the prior
  # baseline. Scoped to this family.
  def latest_completed_forecast_group(excluding: nil)
    scope = forecast_run_groups
      .where(status: "completed")
      .includes(forecast_runs: :forecast_days)
      .order(created_at: :desc)
    scope = scope.where.not(id: excluding.id) if excluding
    scope.first
  end

  # The author for scheduled runs: a preview-enabled member (admins first) so
  # the run group/review is attributed to a real, eligible family user.
  def scheduled_forecast_author
    users.with_preview_features.order(Arel.sql("CASE role WHEN 'super_admin' THEN 0 WHEN 'admin' THEN 1 ELSE 2 END"), :created_at).first
  end
end
