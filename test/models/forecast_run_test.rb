require "test_helper"

class ForecastRunTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @user = users(:family_admin)
    @group = ForecastRunGroup.create!(
      family: @family,
      user: @user,
      name: "Manual run",
      run_type: "manual",
      currency: @family.currency,
      horizon_start_on: Date.current,
      horizon_end_on: 36.months.from_now.to_date,
      daily_until_on: 90.days.from_now.to_date
    )
  end

  test "requires scenario stack snapshot" do
    run = @group.forecast_runs.build(
      family: @family,
      user: @user,
      scenario_stack_key: "baseline"
    )

    assert_not run.valid?
    assert_includes run.errors[:scenario_stack_snapshot], "can't be blank"
  end

  test "completed runs are immutable" do
    run = @group.forecast_runs.create!(
      family: @family,
      user: @user,
      scenario_stack_key: "baseline",
      scenario_stack_snapshot: { "key" => "baseline" },
      status: "completed",
      feasibility_status: "pass",
      currency: @family.currency,
      input_snapshot: valid_input_snapshot
    )

    assert_not run.update(risk_flags: [ { "type" => "changed_after_completion" } ])
    assert_includes run.errors[:base], "completed forecast output is immutable"
  end

  test "child rows are immutable after parent run completes" do
    run = @group.forecast_runs.create!(
      family: @family,
      user: @user,
      scenario_stack_key: "baseline",
      scenario_stack_snapshot: { "key" => "baseline" },
      status: "running",
      feasibility_status: "unknown",
      currency: @family.currency,
      input_snapshot: valid_input_snapshot
    )
    day = run.forecast_days.create!(
      date: Date.current,
      scenario_stack_key: "baseline",
      currency: @family.currency
    )

    run.update!(status: "completed", feasibility_status: "pass")

    assert_not day.update(cash_balance: 1)
    assert_includes day.errors[:base], "completed forecast output is immutable"
  end

  test "cannot append child rows after parent run completes" do
    run = @group.forecast_runs.create!(
      family: @family,
      user: @user,
      scenario_stack_key: "baseline",
      scenario_stack_snapshot: { "key" => "baseline" },
      status: "completed",
      feasibility_status: "pass",
      currency: @family.currency,
      input_snapshot: valid_input_snapshot
    )

    day = run.forecast_days.build(
      date: Date.current,
      scenario_stack_key: "baseline",
      currency: @family.currency
    )

    assert_not day.save
    assert_includes day.errors[:base], "completed forecast output is immutable"
  end

  test "cannot reparent child rows away from a completed run" do
    completed_run = @group.forecast_runs.create!(
      family: @family,
      user: @user,
      scenario_stack_key: "completed",
      scenario_stack_snapshot: { "key" => "completed" },
      status: "running",
      feasibility_status: "unknown",
      currency: @family.currency,
      input_snapshot: valid_input_snapshot
    )
    day = completed_run.forecast_days.create!(
      date: Date.current,
      scenario_stack_key: "completed",
      currency: @family.currency
    )
    completed_run.update!(status: "completed", feasibility_status: "pass")
    open_run = @group.forecast_runs.create!(
      family: @family,
      user: @user,
      scenario_stack_key: "open",
      scenario_stack_snapshot: { "key" => "open" },
      status: "running",
      feasibility_status: "unknown",
      currency: @family.currency
    )

    assert_not day.update(forecast_run: open_run)
    assert_includes day.errors[:base], "completed forecast output is immutable"
  end

  test "forecast effect category projections are valid output rows" do
    run = @group.forecast_runs.create!(
      family: @family,
      user: @user,
      scenario_stack_key: "baseline",
      scenario_stack_snapshot: { "key" => "baseline" },
      status: "running",
      feasibility_status: "unknown",
      currency: @family.currency
    )
    month = run.forecast_months.create!(
      period_start_on: Date.current.beginning_of_month,
      period_end_on: Date.current.end_of_month,
      precision: "daily_backed",
      scenario_stack_key: "baseline",
      currency: @family.currency
    )

    projection = month.forecast_category_projections.build(
      category: categories(:subcategory),
      projection_key: categories(:subcategory).id,
      source: "forecast_effect",
      currency: @family.currency,
      planned_spending: 300,
      projected_spending_low: 300,
      projected_spending_expected: 300,
      projected_spending_high: 300,
      projected_spending: 300,
      source_snapshot: { "category" => { "id" => categories(:subcategory).id, "name" => categories(:subcategory).name } }
    )

    assert projection.valid?
  end

  test "generated category projections allow forecast budget override source" do
    run = @group.forecast_runs.create!(
      family: @family,
      user: @user,
      scenario_stack_key: "baseline",
      scenario_stack_snapshot: { "key" => "baseline" },
      status: "running",
      feasibility_status: "unknown",
      currency: @family.currency
    )
    month = run.forecast_months.create!(
      period_start_on: Date.current.beginning_of_month,
      period_end_on: Date.current.end_of_month,
      precision: "daily_backed",
      scenario_stack_key: "baseline",
      currency: @family.currency
    )

    projection = month.forecast_category_projections.build(
      category: categories(:food_and_drink),
      projection_key: categories(:food_and_drink).id,
      source: "forecast_budget_override",
      currency: @family.currency,
      budgeted_spending: 900,
      projected_spending_low: 900,
      projected_spending_expected: 900,
      projected_spending_high: 900,
      projected_spending: 900,
      source_snapshot: { "forecast_budget_override" => { "id" => SecureRandom.uuid } }
    )

    assert projection.valid?
  end

  test "generated category projections require source snapshots" do
    run = @group.forecast_runs.create!(
      family: @family,
      user: @user,
      scenario_stack_key: "baseline",
      scenario_stack_snapshot: { "key" => "baseline" },
      status: "running",
      feasibility_status: "unknown",
      currency: @family.currency
    )
    month = run.forecast_months.create!(
      period_start_on: Date.current.beginning_of_month,
      period_end_on: Date.current.end_of_month,
      precision: "daily_backed",
      scenario_stack_key: "baseline",
      currency: @family.currency
    )
    projection = month.forecast_category_projections.build(
      category: categories(:subcategory),
      projection_key: categories(:subcategory).id,
      source: "forecast_effect",
      currency: @family.currency
    )

    assert_not projection.valid?
    assert_includes projection.errors[:source_snapshot], "must explain the generated output"
  end

  test "generated debt projections require source snapshots" do
    run = @group.forecast_runs.create!(
      family: @family,
      user: @user,
      scenario_stack_key: "baseline",
      scenario_stack_snapshot: { "key" => "baseline" },
      status: "running",
      feasibility_status: "unknown",
      currency: @family.currency
    )
    month = run.forecast_months.create!(
      period_start_on: Date.current.beginning_of_month,
      period_end_on: Date.current.end_of_month,
      precision: "daily_backed",
      scenario_stack_key: "baseline",
      currency: @family.currency
    )
    projection = month.forecast_debt_projections.build(
      projection_key: "debt-account",
      source: "account_balance_only",
      currency: @family.currency
    )

    assert_not projection.valid?
    assert_includes projection.errors[:source_snapshot], "must explain the generated output"
  end

  test "generated goal evaluations require goal snapshots" do
    run = @group.forecast_runs.create!(
      family: @family,
      user: @user,
      scenario_stack_key: "baseline",
      scenario_stack_snapshot: { "key" => "baseline" },
      status: "running",
      feasibility_status: "unknown",
      currency: @family.currency
    )
    evaluation = run.forecast_goal_evaluations.build(
      goal_key: "goal:missing",
      scenario_stack_key: "baseline",
      status: "pass"
    )

    assert_not evaluation.valid?
    assert_includes evaluation.errors[:goal_snapshot], "must explain the generated output"
  end

  test "goal evaluation uniqueness survives source goal deletion" do
    run = @group.forecast_runs.create!(
      family: @family,
      user: @user,
      scenario_stack_key: "baseline",
      scenario_stack_snapshot: { "key" => "baseline" },
      status: "running",
      feasibility_status: "unknown",
      currency: @family.currency
    )
    goal = @family.forecast_goals.create!(
      name: "Emergency buffer",
      goal_type: "minimum_cash_balance",
      target_amount: 1000,
      currency: @family.currency
    )
    goal_key = "forecast_goal:#{goal.id}"
    snapshot = goal.attributes
    run.forecast_goal_evaluations.create!(
      forecast_goal: goal,
      goal_key: goal_key,
      scenario_stack_key: "baseline",
      status: "pass",
      goal_snapshot: snapshot
    )
    goal.destroy!

    duplicate = run.forecast_goal_evaluations.build(
      goal_key: goal_key,
      scenario_stack_key: "baseline",
      status: "pass",
      goal_snapshot: snapshot
    )

    assert_not duplicate.valid?
    assert_includes duplicate.errors[:goal_key], "has already been taken"
  end

  test "forecast reviews can move through workflow after run group completes" do
    @group.forecast_runs.create!(
      family: @family,
      user: @user,
      scenario_stack_key: "baseline",
      scenario_stack_snapshot: { "key" => "baseline" },
      status: "completed",
      feasibility_status: "pass",
      currency: @family.currency,
      input_snapshot: valid_input_snapshot
    )
    @group.update!(status: "completed")

    review = @group.create_forecast_review!(
      family: @family,
      user: @user,
      source: "manual",
      status: "draft"
    )

    assert review.update(status: "approved", approved_at: Time.current)
  end

  test "forecast run group has one active review target" do
    @group.create_forecast_review!(
      family: @family,
      user: @user,
      source: "manual",
      status: "draft"
    )

    duplicate = ForecastReview.new(
      forecast_run_group: @group,
      family: @family,
      user: @user,
      source: "manual",
      status: "draft"
    )

    assert_not duplicate.valid?
    assert_includes duplicate.errors[:forecast_run_group_id], "has already been taken"
  end

  test "cannot append runs after run group completes" do
    @group.forecast_runs.create!(
      family: @family,
      user: @user,
      scenario_stack_key: "baseline",
      scenario_stack_snapshot: { "key" => "baseline" },
      status: "completed",
      feasibility_status: "pass",
      currency: @family.currency,
      input_snapshot: valid_input_snapshot
    )
    @group.update!(status: "completed")

    run = @group.forecast_runs.build(
      family: @family,
      user: @user,
      scenario_stack_key: "late",
      scenario_stack_snapshot: { "key" => "late" },
      currency: @family.currency
    )

    assert_not run.save
    assert_includes run.errors[:base], "completed forecast output is immutable"
  end

  test "completed run groups require completed child runs" do
    assert_not @group.update(status: "completed")
    assert_includes @group.errors[:base], "completed forecast run groups require at least one completed run"
  end

  test "completed runs require runner input snapshot sections" do
    run = @group.forecast_runs.build(
      family: @family,
      user: @user,
      scenario_stack_key: "baseline",
      scenario_stack_snapshot: { "key" => "baseline" },
      status: "completed",
      feasibility_status: "pass",
      currency: @family.currency,
      input_snapshot: { "source_data_versions" => {} }
    )

    assert_not run.valid?
    assert_includes run.errors[:input_snapshot], "must include runner source sections"
  end

  private
    def valid_input_snapshot
      {
        "scenario_stack" => { "key" => "baseline" },
        "currency" => @family.currency,
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
