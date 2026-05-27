require "test_helper"

class Debt::ReconciliationServiceTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:loan)
    @profile = DebtProfile.create!(account: @account)
    @event = DebtEvent.create!(
      account: @account,
      debt_profile: @profile,
      event_type: "interest_accrual",
      status: "pending",
      event_date: Date.new(2026, 1, 31),
      amount: 125.25,
      currency: "USD"
    )
  end

  test "accepts one exact manual entry match" do
    entry = create_interest_entry(amount: 125.25)

    match = Debt::ReconciliationService.new(@event).call

    assert_equal entry, match.entry
    assert_equal "accepted", match.status
    assert_equal "matched", @event.reload.status
    assert_equal entry, @event.entry
  end

  test "does not match ambiguous candidates" do
    create_interest_entry(amount: 125.25, name: "Interest charge 1")
    create_interest_entry(amount: 125.25, name: "Interest charge 2")

    assert_nil Debt::ReconciliationService.new(@event).call
    assert_equal "pending", @event.reload.status
  end

  test "ignores pending and excluded candidates" do
    create_interest_entry(
      amount: 125.25,
      extra: { "plaid" => { "pending" => true } }
    )
    create_interest_entry(amount: 125.25, excluded: true)

    assert_nil Debt::ReconciliationService.new(@event).call
  end

  test "ignores entries already accepted for another event" do
    entry = create_interest_entry(amount: 125.25)
    other_event = DebtEvent.create!(
      account: @account,
      debt_profile: @profile,
      event_type: "interest_accrual",
      status: "pending",
      event_date: Date.new(2026, 1, 31),
      amount: 125.25,
      currency: "USD"
    )
    DebtReconciliationMatch.create!(
      account: @account,
      debt_event: other_event,
      entry: entry,
      match_type: "exact",
      confidence: "high",
      status: "accepted",
      matched_on: Date.current
    )

    assert_nil Debt::ReconciliationService.new(@event).call
  end

  test "does not reconcile connected debt accounts" do
    AccountProvider.create!(account: @account, provider: plaid_accounts(:one))
    create_interest_entry(amount: 125.25)

    assert_nil Debt::ReconciliationService.new(@event).call
  end

  private
    def create_interest_entry(amount:, name: "Interest charge", excluded: false, extra: {})
      @account.entries.create!(
        date: Date.new(2026, 1, 31),
        name: name,
        amount: amount,
        currency: "USD",
        excluded: excluded,
        entryable: Transaction.new(kind: "standard", extra: extra)
      )
    end
end
