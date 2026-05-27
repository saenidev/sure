require "test_helper"

class DebtPostingRunTest < ActiveSupport::TestCase
  test "accepts a liability account posting run" do
    account = accounts(:loan)
    profile = DebtProfile.create!(account: account)

    run = DebtPostingRun.new(
      account: account,
      debt_profile: profile,
      run_type: "interest_accrual",
      status: "started"
    )

    assert run.valid?
  end

  test "rejects asset account posting run" do
    run = DebtPostingRun.new(
      account: accounts(:depository),
      run_type: "interest_accrual",
      status: "started"
    )

    assert_not run.valid?
    assert_includes run.errors[:account], "must be a liability account"
  end
end
