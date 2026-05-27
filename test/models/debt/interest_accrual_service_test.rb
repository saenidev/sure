require "test_helper"

class Debt::InterestAccrualServiceTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:loan)
    @account.update!(balance: 1200)
    @profile = DebtProfile.create!(
      account: @account,
      auto_accrual_enabled: true,
      last_accrued_on: Date.new(2026, 1, 30)
    )
    DebtRatePeriod.create!(
      debt_profile: @profile,
      rate_type: "fixed",
      annual_rate: 12,
      starts_on: Date.new(2026, 1, 1)
    )
  end

  test "posts daily interest to the debt ledger" do
    event = Debt::InterestAccrualService.new(account: @account, as_of: Date.new(2026, 1, 31)).call

    assert_equal "posted", event.status
    assert_equal "interest_accrual", event.event_type
    assert_equal BigDecimal("0.3945"), event.amount
    assert_equal Date.new(2026, 1, 31), @profile.reload.last_accrued_on

    entry = event.entry
    assert_equal @account, entry.account
    assert_equal BigDecimal("0.3945"), entry.amount
    assert_equal "sure", entry.source
    assert entry.user_modified?
    assert_equal "standard", entry.transaction.kind

    run = @account.debt_posting_runs.last
    assert_equal "interest_accrual", run.run_type
    assert_equal "succeeded", run.status
  end

  test "is idempotent for the same accrual period" do
    first_event = Debt::InterestAccrualService.new(account: @account, as_of: Date.new(2026, 1, 31)).call
    second_event = Debt::InterestAccrualService.new(account: @account, as_of: Date.new(2026, 1, 31)).call

    assert_equal first_event, second_event
    assert_equal 1, @account.debt_events.where(event_type: "interest_accrual").count
    assert_equal 1, @account.entries.where(source: "sure").count
  end

  test "reuses a pending accrual event for retry" do
    pending_event = DebtEvent.create!(
      account: @account,
      debt_profile: @profile,
      event_type: "interest_accrual",
      status: "pending",
      event_date: Date.new(2026, 1, 31),
      period_start_on: Date.new(2026, 1, 31),
      period_end_on: Date.new(2026, 1, 31),
      amount: 0.3945,
      currency: "USD",
      source: "sure",
      idempotency_key: "interest_accrual:2026-01-31:2026-01-31"
    )

    event = Debt::InterestAccrualService.new(account: @account, as_of: Date.new(2026, 1, 31)).call

    assert_equal pending_event, event
    assert_equal "posted", event.status
    assert_equal 1, @account.debt_events.where(event_type: "interest_accrual").count
  end

  test "voided accrual event does not block a replacement posting" do
    DebtEvent.create!(
      account: @account,
      debt_profile: @profile,
      event_type: "interest_accrual",
      status: "voided",
      event_date: Date.new(2026, 1, 31),
      period_start_on: Date.new(2026, 1, 31),
      period_end_on: Date.new(2026, 1, 31),
      amount: 0.3945,
      currency: "USD",
      source: "sure",
      idempotency_key: "interest_accrual:2026-01-31:2026-01-31"
    )

    event = Debt::InterestAccrualService.new(account: @account, as_of: Date.new(2026, 1, 31)).call

    assert_equal "posted", event.status
    assert_match(/:retry:/, event.idempotency_key)
    assert_equal 2, @account.debt_events.where(event_type: "interest_accrual").count
  end

  test "matches an existing manual interest entry instead of posting a duplicate" do
    manual_entry = @account.entries.create!(
      date: Date.new(2026, 1, 31),
      name: "Manual interest charge",
      amount: 0.3945,
      currency: "USD",
      entryable: Transaction.new(kind: "standard")
    )

    event = Debt::InterestAccrualService.new(account: @account, as_of: Date.new(2026, 1, 31)).call

    assert_equal "matched", event.status
    assert_equal manual_entry, event.entry
    assert_equal 0, @account.entries.where(source: "sure").count
  end

  test "skips connected debt accounts" do
    AccountProvider.create!(account: @account, provider: plaid_accounts(:one))

    assert_nil Debt::InterestAccrualService.new(account: @account, as_of: Date.new(2026, 1, 31)).call
    assert_equal 0, @account.debt_events.count
  end
end
