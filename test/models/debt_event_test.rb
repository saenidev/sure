require "test_helper"

class DebtEventTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:loan)
    @profile = DebtProfile.create!(account: @account)
  end

  test "posted interest event requires a ledger entry" do
    event = DebtEvent.new(
      account: @account,
      debt_profile: @profile,
      event_type: "interest_accrual",
      status: "posted",
      event_date: Date.new(2026, 1, 31),
      amount: 100,
      currency: "USD"
    )

    assert_not event.valid?
    assert_includes event.errors[:entry], "must be present for posted or matched balance-changing events"
  end

  test "pending interest event can exist without entry" do
    event = DebtEvent.new(
      account: @account,
      debt_profile: @profile,
      event_type: "interest_accrual",
      status: "pending",
      event_date: Date.new(2026, 1, 31),
      amount: 100,
      currency: "USD"
    )

    assert event.valid?
  end

  test "interest capitalization event does not require a ledger entry" do
    event = DebtEvent.new(
      account: @account,
      debt_profile: @profile,
      event_type: "interest_capitalization",
      status: "posted",
      event_date: Date.current,
      amount: 100,
      currency: @account.currency
    )

    assert event.valid?
  end

  test "linked entry must belong to event account" do
    other_entry = accounts(:credit_card).entries.create!(
      date: Date.new(2026, 1, 31),
      name: "Interest Charge",
      amount: 100,
      currency: "USD",
      entryable: Transaction.new
    )

    event = DebtEvent.new(
      account: @account,
      debt_profile: @profile,
      entry: other_entry,
      event_type: "interest_accrual",
      status: "posted",
      event_date: Date.new(2026, 1, 31),
      amount: 100,
      currency: "USD"
    )

    assert_not event.valid?
    assert_includes event.errors[:entry], "must belong to account"
  end
end
