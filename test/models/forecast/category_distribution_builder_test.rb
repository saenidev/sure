require "test_helper"

class Forecast::CategoryDistributionBuilderTest < ActiveSupport::TestCase
  test "builds conservative distribution bands around budgeted amount" do
    result = Forecast::CategoryDistributionBuilder.new(category: categories(:food_and_drink), expected_amount: 100).call

    assert_equal 85.to_d, result.low
    assert_equal 100.to_d, result.expected
    assert_equal 115.to_d, result.high
    assert_equal "budget_variance_fallback", result.source
  end
end
