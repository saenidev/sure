module ForecastRunGroupTestHelper
  # Builds a persisted, completed ForecastRunGroup with the given number of
  # completed runs (scenario stacks). Mirrors how Forecast::Runner persists
  # output: create a pending group, attach completed runs with a valid input
  # snapshot, then flip the group to completed (which the immutability concern
  # only locks once it is already completed in the DB).
  def build_completed_run_group(family:, user: nil, runs: 1, created_at: nil, finished_at: Time.current)
    user ||= family.users.first
    group = family.forecast_run_groups.create!(
      user: user,
      name: "Manual run",
      run_type: "manual",
      currency: family.currency,
      horizon_start_on: Date.current,
      horizon_end_on: 36.months.from_now.to_date,
      daily_until_on: 90.days.from_now.to_date
    )

    runs.times do |i|
      group.forecast_runs.create!(
        family: family,
        user: user,
        scenario_stack_key: "baseline-#{i}",
        scenario_stack_snapshot: { "key" => "baseline-#{i}" },
        status: "completed",
        feasibility_status: "pass",
        currency: family.currency,
        input_snapshot: forecast_valid_input_snapshot(family)
      )
    end

    group.update!(status: "completed", finished_at: finished_at)
    group.update_column(:created_at, created_at) if created_at
    group
  end

  # Builds a persisted, failed ForecastRunGroup carrying an error message.
  def build_failed_run_group(family:, user: nil, error_message: "MoneyConverter::MissingRate: no rate", created_at: nil)
    user ||= family.users.first
    group = family.forecast_run_groups.create!(
      user: user,
      name: "Manual run",
      run_type: "manual",
      status: "failed",
      currency: family.currency,
      horizon_start_on: Date.current,
      horizon_end_on: 36.months.from_now.to_date,
      daily_until_on: 90.days.from_now.to_date,
      error_message: error_message,
      finished_at: Time.current
    )
    group.update_column(:created_at, created_at) if created_at
    group
  end

  def forecast_valid_input_snapshot(family)
    {
      "scenario_stack" => { "key" => "baseline" },
      "currency" => family.currency,
      "source_data_versions" => {},
      "portfolio" => {},
      "accounts" => [],
      "budget_income" => [],
      "budget_categories" => [],
      "recurring_items" => [],
      "pending_entries" => [],
      "forecast_events" => [],
      "debt_rows" => [],
      "goals" => [],
      "account_count" => 0,
      "budget_period_count" => 0,
      "recurring_item_count" => 0,
      "pending_entry_count" => 0,
      "forecast_event_count" => 0,
      "goal_count" => 0
    }
  end
end
