require "test_helper"

class DebtProfileTest < ActiveSupport::TestCase
  setup do
    @loan_account = accounts(:loan)
    @asset_account = accounts(:depository)
  end

  test "accepts liability account" do
    profile = DebtProfile.new(account: @loan_account, status: "active")

    assert profile.valid?
  end

  test "rejects asset account" do
    profile = DebtProfile.new(account: @asset_account, status: "active")

    assert_not profile.valid?
    assert_includes profile.errors[:account], "must be a liability account"
  end

  test "validates day fields" do
    profile = DebtProfile.new(
      account: @loan_account,
      payment_due_day: 32,
      statement_closing_day: 0
    )

    assert_not profile.valid?
    assert_includes profile.errors[:payment_due_day], "must be between 1 and 31"
    assert_includes profile.errors[:statement_closing_day], "must be between 1 and 31"
  end

  test "effective end cannot be before start" do
    profile = DebtProfile.new(
      account: @loan_account,
      effective_start_on: Date.new(2026, 2, 1),
      effective_end_on: Date.new(2026, 1, 1)
    )

    assert_not profile.valid?
    assert_includes profile.errors[:effective_end_on], "must be on or after effective_start_on"
  end

  test "defaults effective start date when automatic accrual is enabled" do
    travel_to Date.new(2026, 1, 31) do
      profile = DebtProfile.create!(
        account: @loan_account,
        status: "active",
        auto_accrual_enabled: true
      )

      assert_equal Date.new(2026, 1, 31), profile.effective_start_on
    end
  end

  test "defaults effective start date when automatic accrual is enabled on an existing profile" do
    profile = DebtProfile.create!(account: @loan_account, status: "active")

    travel_to Date.new(2026, 1, 31) do
      profile.update!(auto_accrual_enabled: true)
    end

    assert_equal Date.new(2026, 1, 31), profile.reload.effective_start_on
  end

  test "preserves explicit effective start date when automatic accrual is enabled" do
    explicit_start = Date.new(2026, 1, 1)

    travel_to Date.new(2026, 1, 31) do
      profile = DebtProfile.create!(
        account: @loan_account,
        status: "active",
        auto_accrual_enabled: true,
        effective_start_on: explicit_start
      )

      assert_equal explicit_start, profile.effective_start_on
    end
  end

  test "does not default effective start date for allocation-only automation" do
    profile = DebtProfile.create!(
      account: @loan_account,
      status: "active",
      auto_payment_allocation_enabled: true
    )

    assert_nil profile.effective_start_on
  end
end
