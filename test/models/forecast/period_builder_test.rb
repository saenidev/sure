require "test_helper"

class Forecast::PeriodBuilderTest < ActiveSupport::TestCase
  test "uses family custom month starts" do
    family = families(:dylan_family)
    family.update!(month_start_day: 15)

    result = Forecast::PeriodBuilder.new(
      family: family,
      start_on: Date.new(2026, 5, 27),
      months: 2,
      daily_days: 90
    ).call

    assert_equal Date.new(2026, 5, 15), result.months.first.start_date
    assert_equal Date.new(2026, 6, 14), result.months.first.end_date
  end

  test "marks only fully covered daily periods as daily backed" do
    family = families(:dylan_family)

    result = Forecast::PeriodBuilder.new(
      family: family,
      start_on: Date.new(2026, 1, 1),
      months: 3,
      daily_days: 40
    ).call

    assert_equal "daily_backed", result.months.first.precision
    assert_equal "monthly", result.months.second.precision
  end

  test "does not mark a partial current period as daily backed" do
    family = families(:dylan_family)

    result = Forecast::PeriodBuilder.new(
      family: family,
      start_on: Date.new(2026, 1, 15),
      months: 1,
      daily_days: 90
    ).call

    assert_equal Date.new(2026, 1, 1), result.months.first.start_date
    assert_equal "monthly", result.months.first.precision
  end
end
