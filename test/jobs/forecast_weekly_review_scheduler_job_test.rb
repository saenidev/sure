require "test_helper"

class ForecastWeeklyReviewSchedulerJobTest < ActiveJob::TestCase
  include ActiveJob::TestHelper

  setup do
    @family_a = families(:dylan_family)
    enable_preview!(users(:family_admin))
    @family_a.forecast_run_groups.delete_all

    # A second eligible family with its own preview-enabled admin + one account.
    @family_b = Family.create!(name: "Second Family", currency: "USD", locale: "en")
    @admin_b = @family_b.users.create!(
      email: "second-admin@example.com", first_name: "Sam", last_name: "Second",
      role: "admin", password: "password123",
      preferences: { "preview_features_enabled" => true }
    )
    @family_b.accounts.create!(name: "B Checking", balance: 1000, currency: "USD", accountable: Depository.new)

    # An ineligible family: has a user but no accounts/scenarios, preview off.
    @family_ineligible = families(:empty)
  end

  test "enqueues exactly one weekly review job per eligible family with that family's id" do
    assert_enqueued_jobs 2, only: ForecastWeeklyReviewJob do
      ForecastWeeklyReviewSchedulerJob.perform_now
    end

    enqueued_family_ids = enqueued_jobs
      .select { |job| job["job_class"] == "ForecastWeeklyReviewJob" }
      .map { |job| job["arguments"].first }

    assert_includes enqueued_family_ids, @family_a.id
    assert_includes enqueued_family_ids, @family_b.id
    assert_not_includes enqueued_family_ids, @family_ineligible.id
  end

  test "excludes families with preview disabled even when they have accounts" do
    disable_preview!(users(:family_admin))

    ForecastWeeklyReviewSchedulerJob.perform_now
    family_ids = enqueued_jobs
      .select { |job| job["job_class"] == "ForecastWeeklyReviewJob" }
      .map { |job| job["arguments"].first }

    assert_not_includes family_ids, @family_a.id
    assert_includes family_ids, @family_b.id
  end

  test "one family's Runner failure does not abort the batch (per-family isolation)" do
    # Force family A's run to fail via a foreign-currency event with no FX rate.
    # The real Runner builds the group, hits MissingRate, persists the group as
    # failed with a message, then re-raises — which the per-family job swallows.
    # Because the fan-out enqueues one job per family, family B runs in its own
    # job and is unaffected.
    scenario = @family_a.forecast_scenarios.create!(
      created_by_user: users(:family_admin), name: "Foreign expense", status: "active",
      starts_on: Date.current, position: 1
    )
    @family_a.forecast_events.create!(
      forecast_scenario: scenario, name: "Unconvertible cost", effect_type: "expense",
      behavior: "additive", amount: 500, currency: "EUR", starts_on: Date.current
    )
    ExchangeRate.stubs(:find_or_fetch_rate)
                .with(from: "EUR", to: "USD", date: anything, cache: false)
                .returns(nil)

    assert_nothing_raised do
      ForecastWeeklyReviewJob.perform_now(@family_a.id)
    end

    # Family A's group is persisted failed with a message.
    group_a = @family_a.forecast_run_groups.where(run_type: "weekly").order(:created_at).last
    assert group_a.failed?, "family A's group should be failed"
    assert group_a.error_message.present?

    # Family B (a different family in the batch) still processes to completion.
    assert_nothing_raised do
      ForecastWeeklyReviewJob.perform_now(@family_b.id)
    end
    group_b = @family_b.forecast_run_groups.where(run_type: "weekly").order(:created_at).last
    assert_not_nil group_b
    assert group_b.completed?, "family B's group should complete despite family A failing"
  end

  private
    def enable_preview!(user)
      user.update!(preferences: (user.preferences || {}).merge("preview_features_enabled" => true))
    end

    def disable_preview!(user)
      user.update!(preferences: (user.preferences || {}).except("preview_features_enabled"))
    end
end
