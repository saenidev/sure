require "test_helper"

class Debt::AccrualScheduleTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:loan)
  end

  test "daily cadence is due when last accrued date is before as_of" do
    profile = DebtProfile.create!(
      account: @account,
      accrual_cadence: "daily",
      last_accrued_on: Date.new(2026, 1, 30)
    )

    schedule = Debt::AccrualSchedule.new(profile: profile, as_of: Date.new(2026, 1, 31))

    assert schedule.due?
    assert_equal Date.new(2026, 1, 31), schedule.period_start_on
    assert_equal Date.new(2026, 1, 31), schedule.period_end_on
  end

  test "daily cadence is not due twice on same date" do
    profile = DebtProfile.create!(
      account: @account,
      accrual_cadence: "daily",
      last_accrued_on: Date.new(2026, 1, 31)
    )

    schedule = Debt::AccrualSchedule.new(profile: profile, as_of: Date.new(2026, 1, 31))

    assert_not schedule.due?
  end

  test "blank cadence behaves as daily for backward compatibility" do
    profile = DebtProfile.create!(
      account: @account,
      accrual_cadence: nil,
      last_accrued_on: Date.new(2026, 1, 30)
    )

    schedule = Debt::AccrualSchedule.new(profile: profile, as_of: Date.new(2026, 1, 31))

    assert schedule.due?
    assert_equal Date.new(2026, 1, 31), schedule.period_start_on
    assert_equal Date.new(2026, 1, 31), schedule.period_end_on
  end

  test "monthly cadence waits for statement closing day" do
    profile = DebtProfile.create!(
      account: @account,
      accrual_cadence: "monthly",
      statement_closing_day: 15,
      last_accrued_on: Date.new(2025, 12, 15)
    )

    before_close = Debt::AccrualSchedule.new(profile: profile, as_of: Date.new(2026, 1, 14))
    on_close = Debt::AccrualSchedule.new(profile: profile, as_of: Date.new(2026, 1, 15))

    assert_not before_close.due?
    assert on_close.due?
    assert_equal Date.new(2025, 12, 16), on_close.period_start_on
    assert_equal Date.new(2026, 1, 15), on_close.period_end_on
  end

  test "monthly cadence uses the anchor date as period end when maintenance runs late" do
    profile = DebtProfile.create!(
      account: @account,
      accrual_cadence: "monthly",
      statement_closing_day: 15,
      last_accrued_on: Date.new(2025, 12, 15)
    )

    schedule = Debt::AccrualSchedule.new(profile: profile, as_of: Date.new(2026, 1, 20))

    assert schedule.due?
    assert_equal Date.new(2025, 12, 16), schedule.period_start_on
    assert_equal Date.new(2026, 1, 15), schedule.period_end_on
  end

  test "monthly cadence is not due again after current month was posted" do
    profile = DebtProfile.create!(
      account: @account,
      accrual_cadence: "monthly",
      statement_closing_day: 15,
      last_accrued_on: Date.new(2026, 1, 15)
    )

    schedule = Debt::AccrualSchedule.new(profile: profile, as_of: Date.new(2026, 1, 31))

    assert_not schedule.due?
  end

  test "monthly cadence falls back to month end without statement closing day" do
    profile = DebtProfile.create!(
      account: @account,
      accrual_cadence: "monthly",
      last_accrued_on: Date.new(2025, 12, 31)
    )

    before_month_end = Debt::AccrualSchedule.new(profile: profile, as_of: Date.new(2026, 1, 30))
    on_month_end = Debt::AccrualSchedule.new(profile: profile, as_of: Date.new(2026, 1, 31))

    assert_not before_month_end.due?
    assert on_month_end.due?
    assert_equal Date.new(2026, 1, 31), on_month_end.period_end_on
  end

  test "monthly cadence clamps statement closing day to the end of short months" do
    profile = DebtProfile.create!(
      account: @account,
      accrual_cadence: "monthly",
      statement_closing_day: 31,
      last_accrued_on: Date.new(2026, 1, 31)
    )

    before_anchor = Debt::AccrualSchedule.new(profile: profile, as_of: Date.new(2026, 2, 27))
    on_anchor = Debt::AccrualSchedule.new(profile: profile, as_of: Date.new(2026, 2, 28))

    assert_not before_anchor.due?
    assert on_anchor.due?
    assert_equal Date.new(2026, 2, 1), on_anchor.period_start_on
    assert_equal Date.new(2026, 2, 28), on_anchor.period_end_on
  end

  test "monthly cadence catches up a missed month end after the month changes" do
    profile = DebtProfile.create!(
      account: @account,
      accrual_cadence: "monthly",
      last_accrued_on: Date.new(2025, 12, 31)
    )

    schedule = Debt::AccrualSchedule.new(profile: profile, as_of: Date.new(2026, 2, 1))

    assert schedule.due?
    assert_equal Date.new(2026, 1, 1), schedule.period_start_on
    assert_equal Date.new(2026, 1, 31), schedule.period_end_on
  end

  test "monthly cadence aggregates multiple missed anchors into one catch-up period" do
    profile = DebtProfile.create!(
      account: @account,
      accrual_cadence: "monthly",
      last_accrued_on: Date.new(2025, 11, 30)
    )

    schedule = Debt::AccrualSchedule.new(profile: profile, as_of: Date.new(2026, 2, 1))

    assert schedule.due?
    assert_equal Date.new(2025, 12, 1), schedule.period_start_on
    assert_equal Date.new(2026, 1, 31), schedule.period_end_on
  end

  test "monthly cadence catches up a missed statement close after the month changes" do
    profile = DebtProfile.create!(
      account: @account,
      accrual_cadence: "monthly",
      statement_closing_day: 15,
      last_accrued_on: Date.new(2025, 12, 15)
    )

    schedule = Debt::AccrualSchedule.new(profile: profile, as_of: Date.new(2026, 2, 1))

    assert schedule.due?
    assert_equal Date.new(2025, 12, 16), schedule.period_start_on
    assert_equal Date.new(2026, 1, 15), schedule.period_end_on
  end

  test "first accrual period starts from effective start date" do
    profile = DebtProfile.create!(
      account: @account,
      accrual_cadence: "daily",
      effective_start_on: Date.new(2026, 1, 10)
    )

    schedule = Debt::AccrualSchedule.new(profile: profile, as_of: Date.new(2026, 1, 31))

    assert schedule.due?
    assert_equal Date.new(2026, 1, 10), schedule.period_start_on
    assert_equal Date.new(2026, 1, 31), schedule.period_end_on
  end

  test "schedule is not due before effective start date" do
    profile = DebtProfile.create!(
      account: @account,
      accrual_cadence: "daily",
      effective_start_on: Date.new(2026, 2, 1)
    )

    schedule = Debt::AccrualSchedule.new(profile: profile, as_of: Date.new(2026, 1, 31))

    assert_not schedule.due?
  end

  test "effective start date caps period start even when last accrued is earlier" do
    profile = DebtProfile.create!(
      account: @account,
      accrual_cadence: "daily",
      effective_start_on: Date.new(2026, 2, 1),
      last_accrued_on: Date.new(2026, 1, 15)
    )

    before_start = Debt::AccrualSchedule.new(profile: profile, as_of: Date.new(2026, 1, 31))
    after_start = Debt::AccrualSchedule.new(profile: profile, as_of: Date.new(2026, 2, 2))

    assert_not before_start.due?
    assert after_start.due?
    assert_equal Date.new(2026, 2, 1), after_start.period_start_on
    assert_equal Date.new(2026, 2, 2), after_start.period_end_on
  end
end
