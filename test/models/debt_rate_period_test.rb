require "test_helper"

class DebtRatePeriodTest < ActiveSupport::TestCase
  setup do
    @profile = DebtProfile.create!(account: accounts(:loan))
  end

  test "rejects overlapping periods for same profile and priority" do
    DebtRatePeriod.create!(
      debt_profile: @profile,
      rate_type: "fixed",
      annual_rate: 6.25,
      starts_on: Date.new(2026, 1, 1),
      ends_on: Date.new(2026, 6, 30),
      priority: 0
    )

    overlap = DebtRatePeriod.new(
      debt_profile: @profile,
      rate_type: "fixed",
      annual_rate: 7.25,
      starts_on: Date.new(2026, 6, 1),
      priority: 0
    )

    assert_not overlap.valid?
    assert_includes overlap.errors[:starts_on], "overlaps an existing rate period"
  end

  test "allows overlapping periods at different priorities" do
    DebtRatePeriod.create!(
      debt_profile: @profile,
      rate_type: "fixed",
      annual_rate: 6.25,
      starts_on: Date.new(2026, 1, 1),
      ends_on: Date.new(2026, 6, 30),
      priority: 0
    )

    promotional = DebtRatePeriod.new(
      debt_profile: @profile,
      rate_type: "promotional",
      annual_rate: 0,
      starts_on: Date.new(2026, 3, 1),
      ends_on: Date.new(2026, 4, 30),
      priority: 10
    )

    assert promotional.valid?
  end
end
