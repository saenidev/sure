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

  # Builds a persisted, completed ForecastRunGroup whose single baseline run
  # carries `days` ForecastDay rows and `months` ForecastMonth rows. Rows are
  # written while the run/group are still non-completed (the immutability concern
  # only locks completed output) and then flipped to completed, mirroring how the
  # Runner persists output. Each row is dated sequentially from `start_on` and
  # carries simple ascending balances so series ordering/values are assertable.
  # Yields each (day, index) and (month, index) to the optional blocks so a test
  # can stamp edge values (e.g. negative cash, risk flags).
  def build_run_group_with_series(family:, user: nil, days: 90, months: 36, start_on: Date.current, day_attrs: nil, month_attrs: nil)
    user ||= family.users.first
    currency = family.currency

    group = family.forecast_run_groups.create!(
      user: user,
      name: "Manual run",
      run_type: "manual",
      currency: currency,
      horizon_start_on: start_on,
      horizon_end_on: start_on + 36.months,
      daily_until_on: start_on + 89.days
    )

    run = group.forecast_runs.create!(
      family: family,
      user: user,
      scenario_stack_key: "baseline",
      scenario_stack_snapshot: { "key" => "baseline" },
      status: "running",
      feasibility_status: "pass",
      currency: currency,
      input_snapshot: forecast_valid_input_snapshot(family)
    )

    days.times do |i|
      attrs = {
        date: start_on + i.days,
        scenario_stack_key: "baseline",
        currency: currency,
        cash_balance: 1000 + (i * 10),
        liquid_balance: 2000 + (i * 10),
        debt_balance: 0,
        net_worth: 3000 + (i * 10),
        risk_flags: []
      }
      attrs.merge!(day_attrs.call(i)) if day_attrs
      run.forecast_days.create!(attrs)
    end

    months.times do |i|
      period_start = start_on + i.months
      attrs = {
        period_start_on: period_start,
        period_end_on: period_start.end_of_month,
        precision: "monthly",
        scenario_stack_key: "baseline",
        currency: currency,
        cash_balance: 1000 + (i * 100),
        liquid_balance: 2000 + (i * 100),
        debt_balance: 0,
        net_worth: 5000 + (i * 100),
        risk_flags: []
      }
      attrs.merge!(month_attrs.call(i)) if month_attrs
      run.forecast_months.create!(attrs)
    end

    run.update!(status: "completed", finished_at: Time.current)
    group.update!(status: "completed", finished_at: Time.current)
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
