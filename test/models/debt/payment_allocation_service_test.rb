require "test_helper"

class Debt::PaymentAllocationServiceTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:loan)
    @profile = DebtProfile.create!(account: @account, auto_payment_allocation_enabled: true)
    @obligation = DebtObligation.create!(
      account: @account,
      debt_profile: @profile,
      due_on: Date.new(2026, 2, 15),
      status: "open",
      statement_balance_amount: 10_000,
      minimum_payment_amount: 500,
      principal_due_amount: 390,
      interest_due_amount: 100,
      fee_due_amount: 10,
      currency: "USD"
    )
    @payment_entry = create_payment_transfer(amount: 500)
  end

  test "allocates liability-side transfer inflow by fee interest then principal" do
    allocation = Debt::PaymentAllocationService.new(entry: @payment_entry).call

    assert_equal @account, allocation.account
    assert_equal @obligation, allocation.debt_obligation
    assert_equal BigDecimal("10"), allocation.fee_amount
    assert_equal BigDecimal("100"), allocation.interest_amount
    assert_equal BigDecimal("390"), allocation.principal_amount
    assert_equal BigDecimal("0"), allocation.unapplied_amount
    assert_equal "allocated", allocation.status
    assert_equal BigDecimal("500"), @obligation.reload.paid_amount
    assert_equal "paid", @obligation.status
  end

  test "marks partial obligation payments for review" do
    @payment_entry.update!(amount: -50)

    allocation = Debt::PaymentAllocationService.new(entry: @payment_entry).call

    assert_equal BigDecimal("10"), allocation.fee_amount
    assert_equal BigDecimal("40"), allocation.interest_amount
    assert_equal BigDecimal("0"), allocation.principal_amount
    assert_equal "needs_review", allocation.status
    assert_equal "partially_paid", @obligation.reload.status
  end

  test "allocates extra payments to principal after scheduled components" do
    @payment_entry.update!(amount: -650)

    allocation = Debt::PaymentAllocationService.new(entry: @payment_entry).call

    assert_equal BigDecimal("10"), allocation.fee_amount
    assert_equal BigDecimal("100"), allocation.interest_amount
    assert_equal BigDecimal("540"), allocation.principal_amount
    assert_equal BigDecimal("0"), allocation.unapplied_amount
    assert_equal "allocated", allocation.status
  end

  test "is idempotent for a payment entry" do
    first = Debt::PaymentAllocationService.new(entry: @payment_entry).call
    second = Debt::PaymentAllocationService.new(entry: @payment_entry).call

    assert_equal first, second
    assert_equal 1, DebtPaymentAllocation.where(entry: @payment_entry).count
  end

  test "skips imported non-transfer entries on manual debt accounts" do
    imported_entry = @account.entries.create!(
      date: Date.new(2026, 2, 1),
      name: "Provider payment",
      amount: -500,
      currency: "USD",
      source: "plaid",
      entryable: Transaction.new(kind: "funds_movement")
    )

    assert_nil Debt::PaymentAllocationService.new(entry: imported_entry).call
  end

  test "skips provider-origin transfer inflows on formerly linked manual accounts" do
    @payment_entry.update!(source: "plaid")

    assert_nil Debt::PaymentAllocationService.new(entry: @payment_entry).call
  end

  test "skips unconfirmed transfer inflows" do
    @payment_entry.transaction.transfer_as_inflow.update!(status: "pending")

    assert_nil Debt::PaymentAllocationService.new(entry: @payment_entry).call
  end

  test "skips connected debt accounts" do
    AccountProvider.create!(account: @account, provider: plaid_accounts(:one))

    assert_nil Debt::PaymentAllocationService.new(entry: @payment_entry).call
  end

  test "skips payment entries before the profile effective start date" do
    @profile.update!(effective_start_on: Date.new(2026, 2, 2))

    assert_nil Debt::PaymentAllocationService.new(entry: @payment_entry).call
    assert_equal 0, DebtPaymentAllocation.where(entry: @payment_entry).count
  end

  test "skips excluded payment entries" do
    @payment_entry.update!(excluded: true)

    assert_nil Debt::PaymentAllocationService.new(entry: @payment_entry).call
    assert_equal 0, DebtPaymentAllocation.where(entry: @payment_entry).count
  end

  test "skips pending payment entries" do
    @payment_entry.transaction.update!(
      extra: {
        "plaid" => {
          "pending" => true
        }
      }
    )

    assert_nil Debt::PaymentAllocationService.new(entry: @payment_entry).call
    assert_equal 0, DebtPaymentAllocation.where(entry: @payment_entry).count
  end

  private
    def create_payment_transfer(amount:)
      cash_entry = accounts(:depository).entries.create!(
        date: Date.new(2026, 2, 1),
        name: "Payment to loan",
        amount: amount,
        currency: "USD",
        entryable: Transaction.new(kind: "loan_payment")
      )
      debt_entry = @account.entries.create!(
        date: Date.new(2026, 2, 1),
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
