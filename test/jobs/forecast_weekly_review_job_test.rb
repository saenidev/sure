require "test_helper"

class ForecastWeeklyReviewJobTest < ActiveJob::TestCase
  setup do
    @family = families(:dylan_family)
    @user = users(:family_admin)
    @family.forecast_run_groups.delete_all
    enable_preview!(@user)
  end

  test "runs the Runner with run_type weekly and creates a draft review for an eligible family" do
    ForecastWeeklyReviewJob.perform_now(@family.id)

    group = @family.forecast_run_groups.order(:created_at).last
    assert_not_nil group, "expected a weekly run group to be created"
    assert_equal "weekly", group.run_type
    assert group.completed?, "expected the weekly run group to complete"

    review = group.forecast_review
    assert_not_nil review, "expected the Runner to create a review shell"
    assert_equal "draft", review.status
    assert_equal "weekly", review.source
  end

  test "is idempotent: a second run on the same day does not create a duplicate weekly group" do
    ForecastWeeklyReviewJob.perform_now(@family.id)
    assert_equal 1, @family.forecast_run_groups.where(run_type: "weekly").count

    assert_no_difference -> { @family.forecast_run_groups.where(run_type: "weekly").count } do
      ForecastWeeklyReviewJob.perform_now(@family.id)
    end
  end

  test "skips a family with forecasting preview disabled" do
    disable_preview!(@user)

    assert_no_difference -> { @family.forecast_run_groups.count } do
      ForecastWeeklyReviewJob.perform_now(@family.id)
    end
  end

  test "skips a family with no visible accounts or scenarios" do
    @family.accounts.update_all(status: "pending_deletion")
    assert_empty @family.forecast_scenarios
    assert_not @family.accounts.visible.exists?

    assert_no_difference -> { @family.forecast_run_groups.count } do
      ForecastWeeklyReviewJob.perform_now(@family.id)
    end
  end

  test "passes exactly the target family to the Runner (no cross-family leakage)" do
    captured_family = nil

    Forecast::Runner.expects(:new).with do |kwargs|
      captured_family = kwargs[:family]
      kwargs[:run_type] == "weekly" && kwargs[:scenario_stacks] == [ [] ]
    end.returns(stub(call: nil))

    ForecastWeeklyReviewJob.perform_now(@family.id)

    assert_equal @family.id, captured_family.id
  end

  test "includes a combined active-scenario comparison stack when the family has active scenarios" do
    scenario = @family.forecast_scenarios.create!(
      created_by_user: @user, name: "Active plan", status: "active", starts_on: Date.current, position: 1
    )

    captured_stacks = nil
    Forecast::Runner.expects(:new).with do |kwargs|
      captured_stacks = kwargs[:scenario_stacks]
      true
    end.returns(stub(call: nil))

    ForecastWeeklyReviewJob.perform_now(@family.id)

    assert_equal [ [], [ scenario.id ] ], captured_stacks
  end

  test "rescues a Runner failure and persists the group failed without raising" do
    # A foreign-currency event with no FX rate forces the Runner to raise
    # MissingRate; the Runner persists the failed group + message before
    # re-raising, and the job must swallow it (one bad family never aborts the batch).
    scenario = @family.forecast_scenarios.create!(
      created_by_user: @user, name: "Foreign expense", status: "active", starts_on: Date.current, position: 1
    )
    @family.forecast_events.create!(
      forecast_scenario: scenario, name: "Unconvertible cost", effect_type: "expense",
      behavior: "additive", amount: 500, currency: "EUR", starts_on: Date.current
    )
    ExchangeRate.stubs(:find_or_fetch_rate)
                .with(from: "EUR", to: @family.currency, date: anything, cache: false)
                .returns(nil)

    assert_nothing_raised do
      ForecastWeeklyReviewJob.perform_now(@family.id)
    end

    group = @family.forecast_run_groups.order(:created_at).last
    assert group.failed?, "expected the run group to be failed"
    assert group.error_message.present?, "expected a persisted error message"
  end

  test "returns quietly for a missing family id" do
    assert_nothing_raised do
      ForecastWeeklyReviewJob.perform_now(SecureRandom.uuid)
    end
  end

  private
    def enable_preview!(user)
      user.update!(preferences: (user.preferences || {}).merge("preview_features_enabled" => true))
    end

    def disable_preview!(user)
      user.update!(preferences: (user.preferences || {}).except("preview_features_enabled"))
    end
end
