require "test_helper"

class ForecastRunGroupTest < ActiveSupport::TestCase
  test "user must belong to family" do
    group = ForecastRunGroup.new(
      family: families(:dylan_family),
      user: users(:empty),
      name: "Weekly review",
      run_type: "manual",
      currency: "USD",
      horizon_start_on: Date.current,
      horizon_end_on: 36.months.from_now.to_date,
      daily_until_on: 90.days.from_now.to_date
    )

    assert_not group.valid?
    assert_includes group.errors[:user], "must belong to the forecast family"
  end

  test "superseded group must belong to same family" do
    other_group = ForecastRunGroup.create!(
      family: families(:empty),
      user: users(:empty),
      name: "Other family run",
      run_type: "manual",
      currency: families(:empty).currency,
      horizon_start_on: Date.current,
      horizon_end_on: 36.months.from_now.to_date,
      daily_until_on: 90.days.from_now.to_date
    )

    group = ForecastRunGroup.new(
      family: families(:dylan_family),
      user: users(:family_admin),
      supersedes_forecast_run_group: other_group,
      name: "Weekly review",
      run_type: "manual",
      currency: "USD",
      horizon_start_on: Date.current,
      horizon_end_on: 36.months.from_now.to_date,
      daily_until_on: 90.days.from_now.to_date
    )

    assert_not group.valid?
    assert_includes group.errors[:supersedes_forecast_run_group], "must belong to the forecast family"
  end

  test "user snapshot is not rewritten by later status updates" do
    user = users(:family_admin)
    group = ForecastRunGroup.create!(
      family: families(:dylan_family),
      user: user,
      name: "Manual run",
      run_type: "manual",
      currency: families(:dylan_family).currency,
      horizon_start_on: Date.current,
      horizon_end_on: 36.months.from_now.to_date,
      daily_until_on: 90.days.from_now.to_date
    )
    group.update_column(
      :user_snapshot,
      {
        "id" => user.id,
        "display_name" => "Historical Name",
        "email" => "historical@example.com"
      }
    )

    group.update!(status: "running")

    assert_equal "Historical Name", group.reload.user_snapshot.fetch("display_name")
    assert_equal "historical@example.com", group.user_snapshot.fetch("email")
  end
end
