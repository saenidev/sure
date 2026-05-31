require "test_helper"

class Forecast::PortfolioSnapshotBuilderTest < ActiveSupport::TestCase
  test "raises on missing portfolio FX instead of falling back to one" do
    family = families(:dylan_family)
    account = accounts(:investment)
    account.update!(currency: "EUR", balance: 1000, cash_balance: 100)

    ExchangeRate.expects(:find_or_fetch_rate)
      .with(from: "EUR", to: family.currency, date: Date.current, cache: false)
      .returns(nil)

    assert_raises Forecast::MoneyConverter::MissingRate do
      Forecast::PortfolioSnapshotBuilder.new(
        family: family,
        user: users(:family_admin),
        money_converter: Forecast::MoneyConverter.new(family: family, as_of: Date.current),
        run_date: Date.current
      ).call
    end
  end

  test "holding FX conversion uses the holding snapshot date" do
    family = families(:dylan_family)
    account = accounts(:investment)
    account.update!(currency: "EUR", balance: 1000, cash_balance: 100)
    holdings(:two).destroy!
    holding = holdings(:one)
    holding.update!(currency: "EUR", date: 3.days.ago.to_date, amount: 1000)
    ExchangeRate.expects(:find_or_fetch_rate)
      .with(from: "EUR", to: family.currency, date: Date.current, cache: false)
      .twice
      .returns(OpenStruct.new(rate: 2.to_d, date: Date.current))
    ExchangeRate.expects(:find_or_fetch_rate)
      .with(from: "EUR", to: family.currency, date: holding.date, cache: false)
      .returns(OpenStruct.new(rate: 2.to_d, date: holding.date))

    result = Forecast::PortfolioSnapshotBuilder.new(
      family: family,
      user: users(:family_admin),
      money_converter: Forecast::MoneyConverter.new(family: family, as_of: Date.current),
      run_date: Date.current
    ).call

    assert_equal holding.date.iso8601, result.fetch(:holdings).first.fetch(:source_snapshot).fetch("money").fetch("exchange_rate_date")
  end

  test "market data quality is stamped with the threaded run date instead of today" do
    family = families(:dylan_family)
    run_date = Date.new(2023, 6, 15)
    assert_not_equal Date.current, run_date

    result = Forecast::PortfolioSnapshotBuilder.new(
      family: family,
      user: users(:family_admin),
      money_converter: Forecast::MoneyConverter.new(family: family, as_of: run_date),
      run_date: run_date
    ).call

    assert_equal run_date, result.fetch(:market_data_quality).fetch(:as_of)
  end

  test "omits stale provider holdings when linked investment account is all cash" do
    family = families(:empty)
    user = users(:empty)
    account = family.accounts.create!(
      owner: user,
      name: "All Cash Brokerage",
      balance: 1000,
      cash_balance: 1000,
      currency: "USD",
      accountable: Investment.new
    )
    plaid_account = plaid_accounts(:one)
    account_provider = AccountProvider.create!(account: account, provider: plaid_account)
    security = Security.create!(ticker: "AAPL", name: "Apple")

    account.holdings.create!(
      security: security,
      date: 1.week.ago.to_date,
      qty: 4,
      price: 100,
      amount: 400,
      currency: "USD",
      account_provider: account_provider
    )

    result = Forecast::PortfolioSnapshotBuilder.new(
      family: family,
      user: user,
      money_converter: Forecast::MoneyConverter.new(family: family, as_of: Date.current),
      run_date: Date.current
    ).call

    assert_equal 1000.to_d, result.fetch(:portfolio_value)
    assert_equal 1000.to_d, result.fetch(:cash_balance)
    assert_empty result.fetch(:holdings)
  end
end
