require "test_helper"

class Debt::AccountMaintenanceRunnerTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:loan)
    @account.update!(balance: 1200)
    @profile = DebtProfile.create!(
      account: @account,
      auto_accrual_enabled: true,
      auto_payment_allocation_enabled: true,
      effective_start_on: Date.new(2026, 1, 1),
      payment_due_day: 15,
      minimum_payment_amount: 500,
      last_accrued_on: Date.new(2026, 1, 30)
    )
    DebtRatePeriod.create!(
      debt_profile: @profile,
      rate_type: "fixed",
      annual_rate: 12,
      starts_on: Date.new(2026, 1, 1)
    )
    @payment_entry = create_payment_transfer(amount: 500, date: Date.new(2026, 1, 31))
  end

  test "runs interest accrual obligation generation and payment allocation" do
    result = Debt::AccountMaintenanceRunner.new(account: @account, as_of: Date.new(2026, 1, 31)).call

    assert_equal @account.id, result.account_id
    assert_equal 1, @account.debt_events.where(event_type: "interest_accrual", status: "posted").count
    assert_equal 1, @account.debt_obligations.count
    assert_equal 1, DebtPaymentAllocation.where(entry: @payment_entry).count
    assert_equal 1, result.allocation_ids.size
  end

  test "is idempotent when maintenance runs repeatedly for the same date" do
    first_result = Debt::AccountMaintenanceRunner.new(account: @account, as_of: Date.new(2026, 1, 31)).call
    second_result = Debt::AccountMaintenanceRunner.new(account: @account, as_of: Date.new(2026, 1, 31)).call

    assert_equal first_result.interest_event_id, second_result.interest_event_id
    assert_equal 1, @account.debt_events.where(event_type: "interest_accrual").count
    assert_equal 1, @account.debt_obligations.count
    assert_equal 1, DebtPaymentAllocation.where(entry: @payment_entry).count
  end

  test "skips inactive or unsupported accounts" do
    @profile.update!(status: "disabled")

    result = Debt::AccountMaintenanceRunner.new(account: @account, as_of: Date.new(2026, 1, 31)).call

    assert_equal "inactive_or_unsupported", result.skipped_reason
    assert_equal 0, @account.debt_events.count
    assert_equal 0, DebtPaymentAllocation.where(entry: @payment_entry).count
  end

  test "does not allocate future-dated payments" do
    @payment_entry.update!(date: Date.new(2026, 2, 1))

    Debt::AccountMaintenanceRunner.new(account: @account, as_of: Date.new(2026, 1, 31)).call

    assert_equal 0, DebtPaymentAllocation.where(entry: @payment_entry).count
  end

  test "skips automation before the profile effective start date" do
    @profile.update!(effective_start_on: Date.new(2026, 2, 1))

    result = Debt::AccountMaintenanceRunner.new(account: @account, as_of: Date.new(2026, 1, 31)).call

    assert_equal "not_effective", result.skipped_reason
    assert_equal 0, @account.debt_events.count
    assert_equal 0, @account.debt_obligations.count
    assert_equal 0, DebtPaymentAllocation.where(entry: @payment_entry).count
  end

  test "does not allocate payments before the profile effective start date" do
    @profile.update!(effective_start_on: Date.new(2026, 1, 15))
    @payment_entry.update!(date: Date.new(2026, 1, 14))

    Debt::AccountMaintenanceRunner.new(account: @account, as_of: Date.new(2026, 1, 31)).call

    assert_equal 0, DebtPaymentAllocation.where(entry: @payment_entry).count
  end

  test "does not allocate excluded payments" do
    @payment_entry.update!(excluded: true)

    Debt::AccountMaintenanceRunner.new(account: @account, as_of: Date.new(2026, 1, 31)).call

    assert_equal 0, DebtPaymentAllocation.where(entry: @payment_entry).count
  end

  test "does not allocate payments when allocation automation is disabled" do
    @profile.update!(auto_payment_allocation_enabled: false)

    Debt::AccountMaintenanceRunner.new(account: @account, as_of: Date.new(2026, 1, 31)).call

    assert_equal 0, DebtPaymentAllocation.where(entry: @payment_entry).count
  end

  private
    def create_payment_transfer(amount:, date:)
      cash_entry = accounts(:depository).entries.create!(
        date: date,
        name: "Payment to loan",
        amount: amount,
        currency: "USD",
        entryable: Transaction.new(kind: "loan_payment")
      )
      debt_entry = @account.entries.create!(
        date: date,
        name: "Payment from checking",
        amount: -amount,
        currency: "USD",
        entryable: Transaction.new(kind: "funds_movement")
      )
      Transfer.create!(
        inflow_transaction: debt_entry.transaction,
        outflow_transaction: cash_entry.transaction,
        status: "confirmed"
      )
      debt_entry
    end
end
