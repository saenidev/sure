require "test_helper"

class Debt::MaintenanceRunnerTest < ActiveSupport::TestCase
  setup do
    @loan_account = accounts(:loan)
    @loan_account.update!(balance: 1200)
    @credit_card_account = accounts(:credit_card)
    @credit_card_account.update!(balance: 300)

    DebtProfile.create!(
      account: @loan_account,
      auto_accrual_enabled: true,
      auto_payment_allocation_enabled: true,
      effective_start_on: Date.new(2026, 1, 1),
      payment_due_day: 15,
      last_accrued_on: Date.new(2026, 1, 30)
    )
    DebtRatePeriod.create!(
      debt_profile: @loan_account.debt_profile,
      rate_type: "fixed",
      annual_rate: 12,
      starts_on: Date.new(2026, 1, 1)
    )
    DebtProfile.create!(
      account: @credit_card_account,
      auto_accrual_enabled: false,
      auto_payment_allocation_enabled: false,
      payment_due_day: 10
    )
  end

  test "processes active manual debt profiles with maintenance signals" do
    result = Debt::MaintenanceRunner.new(as_of: Date.new(2026, 1, 31)).call

    assert_equal 2, result.processed_count
    assert_equal 0, result.error_count
    assert_equal 1, @loan_account.debt_events.where(event_type: "interest_accrual").count
    assert_equal 1, @credit_card_account.debt_obligations.count
  end

  test "ignores disabled profiles and profiles without maintenance signals" do
    disabled_account = accounts(:other_liability)
    DebtProfile.create!(
      account: disabled_account,
      status: "disabled",
      payment_due_day: 5
    )
    no_signal_account = @loan_account.family.accounts.create!(
      name: "No signal loan",
      balance: 500,
      currency: "USD",
      accountable: Loan.new
    )
    DebtProfile.create!(
      account: no_signal_account,
      status: "active",
      auto_accrual_enabled: false,
      auto_payment_allocation_enabled: false,
      payment_due_day: nil
    )

    result = Debt::MaintenanceRunner.new(as_of: Date.new(2026, 1, 31)).call

    assert_equal 2, result.processed_count
    assert_equal 0, disabled_account.debt_obligations.count
    assert_equal 0, no_signal_account.debt_obligations.count
  end

  test "continues after an account-level failure" do
    failing_runner = mock
    failing_runner.expects(:call).raises(StandardError, "maintenance failed")

    successful_runner = mock
    successful_runner.expects(:call).returns(
      Debt::AccountMaintenanceRunner::Result.new(
        account_id: @credit_card_account.id,
        interest_event_id: nil,
        obligation_id: nil,
        allocation_ids: [],
        skipped_reason: nil
      )
    )

    Debt::AccountMaintenanceRunner.expects(:new)
      .with(account: @loan_account, as_of: Date.new(2026, 1, 31))
      .returns(failing_runner)
    Debt::AccountMaintenanceRunner.expects(:new)
      .with(account: @credit_card_account, as_of: Date.new(2026, 1, 31))
      .returns(successful_runner)

    result = Debt::MaintenanceRunner.new(as_of: Date.new(2026, 1, 31)).call

    assert_equal 2, result.processed_count
    assert_equal 1, result.error_count
    assert_equal "StandardError", result.errors.first.fetch(:error_class)
    assert_equal "maintenance failed", result.errors.first.fetch(:message)
  end
end
