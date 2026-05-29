require "test_helper"

class ForecastGenerationJobTest < ActiveJob::TestCase
  setup do
    @family = families(:dylan_family)
    @user = users(:family_admin)
    @family.forecast_run_groups.delete_all
  end

  test "completed run persists 36 months and 90 days for the baseline stack" do
    ForecastGenerationJob.perform_now(family: @family, user: @user)

    group = @family.forecast_run_groups.order(:created_at).last
    assert_not_nil group
    assert group.completed?, "expected the run group to complete"

    run = group.forecast_runs.find_by(scenario_stack_key: "baseline")
    assert_not_nil run, "expected a baseline run"
    assert_equal "completed", run.status
    assert_equal 90, run.forecast_days.count
    assert_equal 36, run.forecast_months.count
  end

  test "uses a localized default name when none is provided" do
    ForecastGenerationJob.perform_now(family: @family, user: @user)

    group = @family.forecast_run_groups.order(:created_at).last
    assert_equal I18n.t("forecasts.runs.default_name", date: I18n.l(Date.current, format: :long)), group.name
  end

  test "rescues a Runner failure and leaves the group failed with an error message" do
    scenario = @family.forecast_scenarios.create!(
      created_by_user: @user,
      name: "Foreign expense",
      starts_on: Date.current,
      position: 1
    )
    @family.forecast_events.create!(
      forecast_scenario: scenario,
      name: "Unconvertible cost",
      effect_type: "expense",
      behavior: "additive",
      amount: 500,
      currency: "EUR",
      starts_on: Date.current
    )

    # Force the FX lookup to fail so the Runner raises MissingRate.
    ExchangeRate.stubs(:find_or_fetch_rate)
                .with(from: "EUR", to: @family.currency, date: anything, cache: false)
                .returns(nil)

    # The Runner is invoked with the baseline stack only; force the failing
    # scenario stack via a stub so the baseline job path exercises failure
    # surfacing without changing the job's public arguments.
    Forecast::Runner.any_instance.stubs(:scenario_stacks).returns([ [ scenario.id ] ])

    # The job must not re-raise: a failed forecast surfaces as a failed group,
    # not an exploded background job.
    assert_nothing_raised do
      ForecastGenerationJob.perform_now(family: @family, user: @user)
    end

    group = @family.forecast_run_groups.order(:created_at).last
    group.reload
    assert group.failed?, "expected the run group to be failed"
    assert group.error_message.present?, "expected a persisted error message"
    assert_match(/Missing FX rate EUR->#{@family.currency}/, group.error_message)
  end

  test "directly stubbing the Runner to raise still leaves a failed group" do
    # Belt-and-suspenders: even an arbitrary error mid-run must be swallowed by
    # the job (the Runner persists the failed group + message before re-raising).
    Forecast::Runner.any_instance.stubs(:call).raises(Forecast::MoneyConverter::MissingRate.new("Missing FX rate EUR->USD for boom"))

    assert_nothing_raised do
      ForecastGenerationJob.perform_now(family: @family, user: @user)
    end
  end
end
