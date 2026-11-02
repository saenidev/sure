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

  # Summing raw amounts across currencies added SEK kronor to US dollars and
  # labeled the result in the family currency (a ~$3.7k position reported as
  # ~$34.8k). The total must be converted into the family currency, and each
  # holding must say what it is worth in that currency.
  test "total_value converts foreign-currency holdings into the family currency" do
    user = users(:empty)
    user.family.update!(currency: "USD")
    account = user.family.accounts.create!(
      owner: user, name: "Global Brokerage", balance: 2000, cash_balance: 0,
      currency: "USD", accountable: Investment.new
    )
    ExchangeRate.create!(from_currency: "SEK", to_currency: "USD", date: Date.current, rate: 0.1)
    provider = linked_provider(user, account)

    account.holdings.create!(security: Security.create!(ticker: "SIVE", name: "Sivers"), account_provider: provider,
      date: Date.current, qty: 100, price: 30, amount: 3000, currency: "SEK")
    account.holdings.create!(security: Security.create!(ticker: "IBKR", name: "Interactive Brokers"), account_provider: provider,
      date: Date.current, qty: 2, price: 100, amount: 200, currency: "USD")

    result = Assistant::Function::GetHoldings.new(user).call({ "page" => 1 })

    assert_equal "$500.00", result.fetch(:total_value)
    sive = result.fetch(:holdings).find { |h| h[:ticker] == "SIVE" }
    assert_equal "SEK", sive[:currency]
    assert_in_delta 3000.0, sive[:amount], 0.001
    assert_equal "USD", sive[:family_currency]
    assert_in_delta 300.0, sive[:amount_in_family_currency], 0.001
  end

  test "total_value is omitted with a warning when a holding cannot be converted" do
    user = users(:empty)
    user.family.update!(currency: "USD")
    account = user.family.accounts.create!(
      owner: user, name: "Global Brokerage", balance: 2000, cash_balance: 0,
      currency: "USD", accountable: Investment.new
    )
    account.holdings.create!(security: Security.create!(ticker: "SIVE", name: "Sivers"),
      account_provider: linked_provider(user, account),
      date: Date.current, qty: 100, price: 30, amount: 3000, currency: "SEK")
    ExchangeRate.stubs(:find_or_fetch_rate).returns(nil)

    result = Assistant::Function::GetHoldings.new(user).call({ "page" => 1 })

    assert_nil result.fetch(:total_value)
    assert_match(/SEK/, result.fetch(:total_value_warning))
  end

  private
    # Provider-linked accounts keep holdings in each listing's own currency
    # (IBKR reports a Stockholm stock in SEK); manual ones only in the account's.
    def linked_provider(user, account)
      item = user.family.coinstats_items.create!(name: "CoinStats", api_key: "test-key")
      AccountProvider.create!(account: account, provider: item.coinstats_accounts.create!(name: "Brokerage", currency: "USD"))
    end
  setup do
    @user = users(:family_admin)
    @fn = Assistant::Function::GetHoldings.new(@user)
    @account = accounts(:investment)
    # The fixtures hold only AAPL, so a second ticker on the same account is
    # what tells a filter from no filter.
    @account.holdings.create!(security: securities(:msft), date: Date.current, qty: 3, price: 400, amount: 1200, currency: "USD")
  end

  test "get_holdings filters by security ticker" do
    assert_equal [ "AAPL" ], tickers("securities" => [ "AAPL" ])
    assert_equal [ "MSFT" ], tickers("securities" => [ "MSFT" ])
    assert_equal 1, @fn.call("page" => 1, "securities" => [ "MSFT" ])[:total_results]
  end

  test "get_holdings security filter for a ticker nobody holds returns nothing" do
    assert_empty tickers("securities" => [ "NOPE" ])
  end

  test "get_holdings security filter does not reach another user's private account" do
    private_account = @user.family.accounts.create!(name: "Member Brokerage", accountable: Investment.new, balance: 0, currency: "USD", owner: users(:family_member))
    hidden = private_account.holdings.create!(security: securities(:aapl), date: Date.current, qty: 9, price: 200, amount: 1800, currency: "USD")

    rows = @fn.call("page" => 1, "securities" => [ "AAPL" ])[:holdings]

    assert_includes rows.map { |row| row[:account] }, @account.name, "the user's own AAPL went too"
    assert_not_includes rows.map { |row| row[:account] }, hidden.account.name
  end

  test "get_holdings without a security filter is unchanged" do
    assert_equal [ "AAPL", "MSFT" ], tickers({})
  end

  private

    def tickers(params)
      @fn.call({ "page" => 1 }.merge(params))[:holdings].map { |row| row[:ticker] }.uniq.sort
    end
end
