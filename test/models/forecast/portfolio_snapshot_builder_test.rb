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
end
