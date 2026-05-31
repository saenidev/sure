require "test_helper"

class Assistant::Function::GetHoldingsTest < ActiveSupport::TestCase
  test "call omits securities whose latest snapshot has zero quantity" do
    user = users(:empty)
    account = user.family.accounts.create!(
      owner: user,
      name: "Assistant Brokerage",
      balance: 1000,
      cash_balance: 100,
      currency: "USD",
      accountable: Investment.new
    )
    security = Security.create!(ticker: "AAPL", name: "Apple")

    account.holdings.create!(
      security: security,
      date: 2.days.ago.to_date,
      qty: 5,
      price: 100,
      amount: 500,
      currency: "USD"
    )
    account.holdings.create!(
      security: security,
      date: Date.current,
      qty: 0,
      price: 100,
      amount: 0,
      currency: "USD"
    )

    result = Assistant::Function::GetHoldings.new(user).call({ "page" => 1 })

    assert_empty result.fetch(:holdings)
    assert_equal 0, result.fetch(:total_results)
  end
end
