require "test_helper"
require "ostruct"

class Forecast::MoneyConverterTest < ActiveSupport::TestCase
  test "raises when non-family currency cannot be converted" do
    family = families(:dylan_family)
    ExchangeRate.expects(:find_or_fetch_rate).with(from: "EUR", to: family.currency, date: Date.current, cache: false).returns(nil)

    assert_raises Forecast::MoneyConverter::MissingRate do
      Forecast::MoneyConverter.new(family: family, as_of: Date.current).convert(amount: 10, currency: "EUR", source: "test")
    end
  end

  test "can convert a source amount using an explicit source date" do
    family = families(:dylan_family)
    source_date = 5.days.ago.to_date
    ExchangeRate.expects(:find_or_fetch_rate)
      .with(from: "EUR", to: family.currency, date: source_date, cache: false)
      .returns(OpenStruct.new(rate: 2.to_d, date: source_date))

    result = Forecast::MoneyConverter.new(family: family, as_of: Date.current).convert(amount: 10, currency: "EUR", source: "historical", as_of: source_date)

    assert_equal 20.to_d, result.amount
    assert_equal source_date, result.exchange_rate_date
  end

  test "zero foreign currency amounts do not require an exchange rate" do
    family = families(:dylan_family)
    ExchangeRate.expects(:find_or_fetch_rate).never

    result = Forecast::MoneyConverter.new(family: family, as_of: Date.current).convert(amount: 0, currency: "EUR", source: "zero_minimum_payment")

    assert_equal 0.to_d, result.amount
    assert_equal family.currency, result.currency
    assert_equal "EUR", result.native_currency
    assert_nil result.exchange_rate
    assert_empty result.risk_flags
  end
end
