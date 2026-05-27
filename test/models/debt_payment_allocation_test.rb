require "test_helper"

class DebtPaymentAllocationTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:loan)
    @profile = DebtProfile.create!(account: @account)
    @entry = @account.entries.create!(
      date: Date.new(2026, 2, 1),
      name: "Loan payment",
      amount: -500,
      currency: "USD",
      entryable: Transaction.new(kind: "loan_payment")
    )
  end

  test "validates allocation components match payment magnitude" do
    allocation = DebtPaymentAllocation.new(
      account: @account,
      entry: @entry,
      debt_profile: @profile,
      allocation_method: "automatic",
      status: "allocated",
      principal_amount: 300,
      interest_amount: 100,
      fee_amount: 0,
      unapplied_amount: 0,
      currency: "USD"
    )

    assert_not allocation.valid?
    assert_includes allocation.errors[:base], "allocation components must equal payment magnitude"
  end

  test "allows imbalanced allocation when review is required" do
    allocation = DebtPaymentAllocation.new(
      account: @account,
      entry: @entry,
      debt_profile: @profile,
      allocation_method: "automatic",
      status: "needs_review",
      principal_amount: 300,
      interest_amount: 100,
      currency: "USD"
    )

    assert allocation.valid?
  end

  test "rejects asset account" do
    asset_account = accounts(:depository)
    asset_entry = asset_account.entries.create!(
      date: Date.new(2026, 2, 1),
      name: "Outgoing transfer",
      amount: -500,
      currency: "USD",
      entryable: Transaction.new(kind: "standard")
    )

    allocation = DebtPaymentAllocation.new(
      account: asset_account,
      entry: asset_entry,
      allocation_method: "automatic",
      status: "allocated",
      principal_amount: 500,
      currency: "USD"
    )

    assert_not allocation.valid?
    assert_includes allocation.errors[:account], "must be a liability account"
  end
end
