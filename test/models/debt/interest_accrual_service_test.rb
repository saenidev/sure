require "test_helper"

class Debt::InterestAccrualServiceTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:loan)
    @account.loan.update!(subtype: "student")
    @account.update!(balance: 1200)
    @profile = DebtProfile.create!(
      account: @account,
      auto_accrual_enabled: true,
      effective_start_on: Date.new(2026, 1, 1),
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
    assert_equal "debt_interest", entry.transaction.kind
    assert_includes Transaction::BUDGET_EXCLUDED_KINDS, entry.transaction.kind

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
    assert_equal "debt_interest", manual_entry.reload.transaction.kind
    assert_equal 0, @account.entries.where(source: "sure").count
  end

  test "skips monthly accrual before the statement closing day" do
    @profile.update!(
      accrual_cadence: "monthly",
      statement_closing_day: 15,
      effective_start_on: Date.new(2025, 12, 1),
      last_accrued_on: Date.new(2025, 12, 15)
    )

    assert_nil Debt::InterestAccrualService.new(account: @account, as_of: Date.new(2026, 1, 14)).call
    assert_equal 0, @account.debt_events.where(event_type: "interest_accrual").count
  end

  test "monthly accrual posts through the scheduled anchor when maintenance runs late" do
    @profile.update!(
      accrual_cadence: "monthly",
      statement_closing_day: 15,
      effective_start_on: Date.new(2025, 12, 1),
      last_accrued_on: Date.new(2025, 12, 15)
    )

    event = Debt::InterestAccrualService.new(account: @account, as_of: Date.new(2026, 1, 20)).call

    assert_equal Date.new(2025, 12, 16), event.period_start_on
    assert_equal Date.new(2026, 1, 15), event.period_end_on
    assert_equal Date.new(2026, 1, 15), event.event_date
    assert_equal Date.new(2026, 1, 15), @profile.reload.last_accrued_on

    run = @account.debt_posting_runs.last
    assert_equal Date.new(2025, 12, 16), run.period_start_on
    assert_equal Date.new(2026, 1, 15), run.period_end_on
  end

  test "monthly accrual is idempotent when repeated after a late maintenance run" do
    @profile.update!(
      accrual_cadence: "monthly",
      statement_closing_day: 15,
      effective_start_on: Date.new(2025, 12, 1),
      last_accrued_on: Date.new(2025, 12, 15)
    )

    first_event = Debt::InterestAccrualService.new(account: @account, as_of: Date.new(2026, 1, 20)).call
    second_event = Debt::InterestAccrualService.new(account: @account, as_of: Date.new(2026, 1, 20)).call

    assert_equal first_event, second_event
    assert_equal 1, @account.debt_events.where(event_type: "interest_accrual", period_end_on: Date.new(2026, 1, 15)).count
    assert_equal 1, @account.entries.where(source: "sure").count
  end

  test "monthly accrual catches up the latest unpaid anchor after month changes" do
    @profile.update!(
      accrual_cadence: "monthly",
      statement_closing_day: nil,
      last_accrued_on: Date.new(2025, 12, 31)
    )

    event = Debt::InterestAccrualService.new(account: @account, as_of: Date.new(2026, 2, 1)).call

    assert_equal Date.new(2026, 1, 1), event.period_start_on
    assert_equal Date.new(2026, 1, 31), event.period_end_on
    assert_equal Date.new(2026, 1, 31), event.event_date
    assert_equal Date.new(2026, 1, 31), @profile.reload.last_accrued_on
  end

  test "federal unsubsidized accrual uses principal balance rather than account balance" do
    @account.update!(balance: 10_500)
    @profile.federal_student_loan.assign(
      enabled: true,
      subsidy_type: "unsubsidized",
      school_status: "in_school",
      principal_balance: "10000",
      accrued_interest_balance: "500",
      weighted_average_rate: "7.3"
    )
    @profile.save!
    @profile.debt_rate_periods.destroy_all
    DebtRatePeriod.create!(
      debt_profile: @profile,
      rate_type: "fixed",
      annual_rate: 7.3,
      starts_on: Date.new(2026, 1, 1)
    )

    event = Debt::InterestAccrualService.new(account: @account, as_of: Date.new(2026, 1, 31)).call

    assert_equal BigDecimal("1.9986"), event.amount
    assert_equal BigDecimal("501.9986"), @profile.reload.federal_student_loan.accrued_interest_balance
    assert_equal BigDecimal("10000.0"), @profile.federal_student_loan.principal_balance
    assert_equal "debt_interest", event.entry.transaction.kind
  end

  test "second federal accrual still uses principal after prior posted interest" do
    @account.update!(balance: 10_500)
    @profile.federal_student_loan.assign(
      enabled: true,
      subsidy_type: "unsubsidized",
      school_status: "in_school",
      principal_balance: "10000",
      accrued_interest_balance: "500"
    )
    @profile.save!
    @profile.debt_rate_periods.destroy_all
    DebtRatePeriod.create!(
      debt_profile: @profile,
      rate_type: "fixed",
      annual_rate: 7.3,
      starts_on: Date.new(2026, 1, 1)
    )

    Debt::InterestAccrualService.new(account: @account, as_of: Date.new(2026, 1, 31)).call
    @account.update!(balance: 10_501.9986)
    event = Debt::InterestAccrualService.new(account: @account, as_of: Date.new(2026, 2, 1)).call

    assert_equal BigDecimal("1.9986"), event.amount
    assert_equal BigDecimal("503.9972"), @profile.reload.federal_student_loan.accrued_interest_balance
    assert_equal BigDecimal("10000.0"), @profile.federal_student_loan.principal_balance
  end

  test "federal subsidized in school advances last accrued without ledger interest" do
    @profile.federal_student_loan.assign(
      enabled: true,
      subsidy_type: "subsidized",
      school_status: "in_school",
      principal_balance: "10000",
      accrued_interest_balance: "0",
      weighted_average_rate: "7.3"
    )
    @profile.save!

    assert_nil Debt::InterestAccrualService.new(account: @account, as_of: Date.new(2026, 1, 31)).call
    assert_equal 0, @account.debt_events.where(event_type: "interest_accrual").count
    assert_equal Date.new(2026, 1, 31), @profile.reload.last_accrued_on
  end

  test "federal accrual rolls back event entry and accrued-interest JSON on posting failure" do
    @profile.federal_student_loan.assign(
      enabled: true,
      subsidy_type: "unsubsidized",
      school_status: "repayment",
      principal_balance: "10000",
      accrued_interest_balance: "500"
    )
    @profile.save!
    Entry.any_instance.stubs(:sync_account_later).raises(StandardError, "forced failure")

    assert_raises(StandardError) do
      Debt::InterestAccrualService.new(account: @account, as_of: Date.new(2026, 1, 31)).call
    end

    assert_equal 0, @account.debt_events.where(event_type: "interest_accrual").count
    assert_equal 0, @account.entries.where(source: "sure").count
    assert_equal Date.new(2026, 1, 30), @profile.reload.last_accrued_on
    assert_equal BigDecimal("500.0"), @profile.federal_student_loan.accrued_interest_balance
  end

  test "skips accrual before the profile effective start date" do
    @profile.update!(
      effective_start_on: Date.new(2026, 2, 1),
      last_accrued_on: nil
    )

    assert_nil Debt::InterestAccrualService.new(account: @account, as_of: Date.new(2026, 1, 31)).call
    assert_equal 0, @account.debt_events.where(event_type: "interest_accrual").count
  end

  test "skips accrual before effective start date when last accrued is earlier" do
    @profile.update!(
      effective_start_on: Date.new(2026, 2, 1),
      last_accrued_on: Date.new(2026, 1, 15)
    )

    assert_nil Debt::InterestAccrualService.new(account: @account, as_of: Date.new(2026, 1, 31)).call
    assert_equal 0, @account.debt_events.where(event_type: "interest_accrual").count
  end

  test "skips connected debt accounts" do
    AccountProvider.create!(account: @account, provider: plaid_accounts(:one))

    assert_nil Debt::InterestAccrualService.new(account: @account, as_of: Date.new(2026, 1, 31)).call
    assert_equal 0, @account.debt_events.count
  end
end
