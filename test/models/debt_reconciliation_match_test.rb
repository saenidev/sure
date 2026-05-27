require "test_helper"

class DebtReconciliationMatchTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:loan)
    @profile = DebtProfile.create!(account: @account)
    @entry = @account.entries.create!(
      date: Date.new(2026, 1, 31),
      name: "Interest Charge",
      amount: 100,
      currency: "USD",
      entryable: Transaction.new
    )
    @event = DebtEvent.create!(
      account: @account,
      debt_profile: @profile,
      event_type: "interest_accrual",
      status: "pending",
      event_date: Date.new(2026, 1, 31),
      amount: 100,
      currency: "USD"
    )
  end

  test "accepting match marks event matched" do
    match = DebtReconciliationMatch.create!(
      account: @account,
      debt_event: @event,
      entry: @entry,
      match_type: "exact",
      confidence: "high",
      status: "accepted",
      matched_on: Date.current
    )

    assert_equal "accepted", match.status
    assert_equal "matched", @event.reload.status
    assert_equal @entry, @event.entry
  end
end
