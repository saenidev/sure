require "test_helper"

class ForecastMarketCloseJobTest < ActiveJob::TestCase
  setup do
    @family = families(:dylan_family)
    @user = users(:family_admin)
    @family.forecast_run_groups.delete_all
    enable_preview!(@user)
  end

  test "material movement flags the draft review and keeps the market_close group" do
    stub_material(true, reasons: %w[portfolio_value_change])

    ForecastMarketCloseJob.perform_now(@family.id)

    group = @family.forecast_run_groups.where(run_type: "market_close").order(:created_at).last
    assert_not_nil group, "a material movement must keep the generated group"
    assert group.completed?

    review = group.forecast_review
    assert_not_nil review
    assert review.triggered?, "the review should be flagged when movement is material"
    assert_equal "material_market_movement", review.response_packet["trigger_reason"]
    assert_includes review.response_packet["trigger_flags"], "portfolio_value_change"
  end

  test "immaterial movement discards the generated group to avoid noise" do
    stub_material(false)

    ForecastMarketCloseJob.perform_now(@family.id)

    group = @family.forecast_run_groups.where(run_type: "market_close").order(:created_at).last
    assert_not_nil group, "an immaterial movement should leave a durable discarded marker"
    assert_equal "discarded", group.status,
      "an immaterial movement must mark the group discarded, not delete it"
  end

  test "a discarded immaterial group suppresses a second same-day re-run" do
    stub_material(false)

    ForecastMarketCloseJob.perform_now(@family.id)
    discarded = @family.forecast_run_groups.where(run_type: "market_close").order(:created_at).last
    assert_equal "discarded", discarded.status

    # A SECOND same-day tick must NOT re-run the Runner (no wasted Runner +
    # MaterialMovement work on a quiet day) and must not stack a new group.
    Forecast::Runner.expects(:new).never
    Forecast::MaterialMovement.expects(:new).never

    assert_no_difference -> { @family.forecast_run_groups.where(run_type: "market_close").count } do
      ForecastMarketCloseJob.perform_now(@family.id)
    end
  end

  test "is idempotent: skips when a same-day market_close group already exists" do
    stub_material(true)
    ForecastMarketCloseJob.perform_now(@family.id)
    assert_equal 1, @family.forecast_run_groups.where(run_type: "market_close").count

    assert_no_difference -> { @family.forecast_run_groups.where(run_type: "market_close").count } do
      ForecastMarketCloseJob.perform_now(@family.id)
    end
  end

  test "skips a family with forecasting preview disabled" do
    disable_preview!(@user)
    Forecast::Runner.expects(:new).never

    assert_no_difference -> { @family.forecast_run_groups.count } do
      ForecastMarketCloseJob.perform_now(@family.id)
    end
  end

  test "skips a family with no visible accounts or scenarios" do
    @family.accounts.update_all(status: "pending_deletion")
    Forecast::Runner.expects(:new).never

    assert_no_difference -> { @family.forecast_run_groups.count } do
      ForecastMarketCloseJob.perform_now(@family.id)
    end
  end

  test "compares against the family's previous completed group only (scoping)" do
    previous = create_completed_market_close_group!
    captured = {}

    Forecast::MaterialMovement.stubs(:new).with do |kwargs|
      captured = kwargs
      true
    end.returns(stub(call: Forecast::MaterialMovement::Result.new(material: true, reasons: [], metrics: {})))

    ForecastMarketCloseJob.perform_now(@family.id)

    assert_equal previous.id, captured[:previous_group].id
    assert_equal @family.id, captured[:current_group].family_id
  end

  test "passes exactly the target family to the Runner (no cross-family leakage)" do
    captured = {}
    stub_material(true)

    Forecast::Runner.expects(:new).with do |kwargs|
      captured = kwargs
      true
    end.returns(stub(call: build_completed_group))

    ForecastMarketCloseJob.perform_now(@family.id)

    assert_equal @family.id, captured[:family].id
    assert_equal "market_close", captured[:run_type]
    assert_equal [ [] ], captured[:scenario_stacks]
  end

  test "rescues a Runner failure and persists the group failed without raising" do
    scenario = @family.forecast_scenarios.create!(
      created_by_user: @user, name: "Foreign expense", status: "active", starts_on: Date.current, position: 1
    )
    @family.forecast_events.create!(
      forecast_scenario: scenario, name: "Unconvertible cost", effect_type: "expense",
      behavior: "additive", amount: 500, currency: "EUR", starts_on: Date.current
    )
    # market_close runs baseline-only, so force the baseline build itself to hit
    # the missing FX rate by stubbing the runner's stacks to the failing scenario.
    Forecast::Runner.any_instance.stubs(:scenario_stacks).returns([ [ scenario.id ] ])
    ExchangeRate.stubs(:find_or_fetch_rate)
                .with(from: "EUR", to: @family.currency, date: anything, cache: false)
                .returns(nil)

    assert_nothing_raised do
      ForecastMarketCloseJob.perform_now(@family.id)
    end

    group = @family.forecast_run_groups.where(run_type: "market_close").order(:created_at).last
    assert group.failed?, "expected the run group to be failed"
    assert group.error_message.present?
  end

  test "returns quietly for a missing family id" do
    assert_nothing_raised do
      ForecastMarketCloseJob.perform_now(SecureRandom.uuid)
    end
  end

  private
    def stub_material(material, reasons: [], metrics: {})
      result = Forecast::MaterialMovement::Result.new(material: material, reasons: reasons, metrics: metrics)
      Forecast::MaterialMovement.any_instance.stubs(:call).returns(result)
    end

    def build_completed_group
      # A minimal group + review so the job's flag branch has a real record to
      # operate on when the Runner is mocked. Built lazily (called from the
      # mocked Runner#call) so it does not exist when the job checks the same-day
      # market_close idempotency guard. run_type "manual" avoids self-colliding
      # with that guard.
      group = @family.forecast_run_groups.create!(
        user: @user, name: "Mocked", run_type: "manual", status: "pending",
        currency: @family.currency, horizon_start_on: Date.current,
        horizon_end_on: Date.current + 36.months, daily_until_on: Date.current + 89.days
      )
      group.create_forecast_review!(family: @family, user: @user, source: "manual", status: "draft")
      group
    end

    def create_completed_market_close_group!
      group = @family.forecast_run_groups.create!(
        user: @user, name: "Prior", run_type: "market_close", status: "pending",
        currency: @family.currency, horizon_start_on: 1.day.ago.to_date,
        horizon_end_on: Date.current + 36.months, daily_until_on: Date.current + 89.days,
        created_at: 1.day.ago
      )
      run = group.forecast_runs.create!(
        family: @family, user: @user, scenario_stack_key: "baseline",
        scenario_stack_snapshot: { "key" => "baseline" }, status: "running", feasibility_status: "unknown",
        currency: @family.currency, input_snapshot: input_snapshot_stub
      )
      run.forecast_days.create!(
        date: 1.day.ago.to_date, scenario_stack_key: "baseline", currency: @family.currency,
        portfolio_value: 100_000, net_worth: 1_000, debt_balance: 0, cash_runway_days: 100
      )
      run.update!(status: "completed", feasibility_status: "pass", finished_at: Time.current)
      group.update!(status: "completed", finished_at: Time.current)
      group
    end

    def input_snapshot_stub
      %w[
        scenario_stack currency source_data_versions portfolio accounts budget_income
        budget_categories recurring_items pending_entries forecast_events debt_rows goals
        account_count budget_period_count recurring_item_count pending_entry_count
        forecast_event_count goal_count
      ].index_with { |_| nil }
    end

    def enable_preview!(user)
      user.update!(preferences: (user.preferences || {}).merge("preview_features_enabled" => true))
    end

    def disable_preview!(user)
      user.update!(preferences: (user.preferences || {}).except("preview_features_enabled"))
    end
end
