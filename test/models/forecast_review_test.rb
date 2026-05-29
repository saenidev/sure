require "test_helper"

class ForecastReviewTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @user = users(:family_admin)
  end

  test "forecast_run_group cannot be reparented after creation" do
    group = build_run_group("Initial run")
    other_group = build_run_group("Other run")

    review = group.create_forecast_review!(
      family: @family,
      user: @user,
      source: "manual",
      status: "draft"
    )

    review.forecast_run_group = other_group

    assert_not review.valid?
    assert_includes review.errors[:forecast_run_group_id], "cannot be changed after the review is created"
  end

  test "status can still change after creation" do
    review = build_run_group("Approvable run").create_forecast_review!(
      family: @family,
      user: @user,
      source: "manual",
      status: "draft"
    )

    assert review.update(status: "approved")
    assert_equal "approved", review.reload.status
  end

  private
    def build_run_group(name)
      ForecastRunGroup.create!(
        family: @family,
        user: @user,
        name: name,
        run_type: "manual",
        currency: @family.currency,
        horizon_start_on: Date.current,
        horizon_end_on: 36.months.from_now.to_date,
        daily_until_on: 90.days.from_now.to_date
      )
    end
end
