require "test_helper"

class Debt::ObligationServiceTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:credit_card)
    @account.update!(balance: 1_000)
    @profile = DebtProfile.create!(
      account: @account,
      payment_due_day: 15,
      minimum_payment_percent: 2.5,
      minimum_payment_amount: 35
    )
  end

  test "generates the next local obligation at or after the as-of date" do
    obligation = Debt::ObligationService.new(account: @account, as_of: Date.new(2026, 1, 20)).generate_next

    assert_equal Date.new(2026, 2, 15), obligation.due_on
    assert_equal BigDecimal("1000"), obligation.statement_balance_amount
    assert_equal BigDecimal("35"), obligation.minimum_payment_amount
    assert_equal "open", obligation.status
    assert_equal "sure", obligation.source
    assert_equal obligation.due_on, @profile.reload.next_due_on
  end

  test "is idempotent for a generated due date" do
    first = Debt::ObligationService.new(account: @account, as_of: Date.new(2026, 1, 20)).generate_next
    second = Debt::ObligationService.new(account: @account, as_of: Date.new(2026, 1, 20)).generate_next

    assert_equal first, second
    assert_equal 1, @account.debt_obligations.count
  end

  test "does not reopen an existing generated obligation" do
    obligation = Debt::ObligationService.new(account: @account, as_of: Date.new(2026, 1, 20)).generate_next
    obligation.update!(status: "paid", paid_amount: obligation.amount_due)

    regenerated = Debt::ObligationService.new(account: @account, as_of: Date.new(2026, 1, 20)).generate_next

    assert_equal obligation, regenerated
    assert_equal "paid", obligation.reload.status
    assert_equal obligation.amount_due, obligation.paid_amount
  end

  test "includes current period posted interest and fees in generated obligation components" do
    @profile.update!(minimum_payment_amount: 100, minimum_payment_percent: nil)
    DebtEvent.create!(
      account: @account,
      debt_profile: @profile,
      entry: @account.entries.create!(
        date: Date.new(2026, 1, 31),
        name: "Interest",
        amount: 30,
        currency: "USD",
        entryable: Transaction.new
      ),
      event_type: "interest_accrual",
      status: "posted",
      event_date: Date.new(2026, 1, 31),
      amount: 30,
      currency: "USD"
    )
    DebtEvent.create!(
      account: @account,
      debt_profile: @profile,
      entry: @account.entries.create!(
        date: Date.new(2026, 2, 1),
        name: "Late fee",
        amount: 5,
        currency: "USD",
        entryable: Transaction.new
      ),
      event_type: "fee",
      status: "posted",
      event_date: Date.new(2026, 2, 1),
      amount: 5,
      currency: "USD"
    )

    obligation = Debt::ObligationService.new(account: @account, as_of: Date.new(2026, 1, 20)).generate_next

    assert_equal BigDecimal("30"), obligation.interest_due_amount
    assert_equal BigDecimal("5"), obligation.fee_due_amount
    assert_equal BigDecimal("65"), obligation.principal_due_amount
  end

  test "clamps payment due day to the end of short months" do
    @profile.update!(payment_due_day: 31)

    obligation = Debt::ObligationService.new(account: @account, as_of: Date.new(2026, 2, 1)).generate_next

    assert_equal Date.new(2026, 2, 28), obligation.due_on
  end

  test "does not generate obligations for connected debt accounts" do
    AccountProvider.create!(account: @account, provider: plaid_accounts(:one))

    assert_nil Debt::ObligationService.new(account: @account, as_of: Date.new(2026, 1, 20)).generate_next
    assert_equal 0, @account.debt_obligations.count
  end
end
