require "test_helper"

class DebtObligationTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:credit_card)
    @profile = DebtProfile.create!(account: @account)
  end

  test "validates non-negative amounts" do
    obligation = DebtObligation.new(
      account: @account,
      debt_profile: @profile,
      due_on: Date.new(2026, 2, 15),
      status: "open",
      minimum_payment_amount: -1,
      paid_amount: -1,
      currency: "USD"
    )

    assert_not obligation.valid?
    assert_includes obligation.errors[:minimum_payment_amount], "must be greater than or equal to 0"
    assert_includes obligation.errors[:paid_amount], "must be greater than or equal to 0"
  end
end
