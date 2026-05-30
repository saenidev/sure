require "test_helper"

class Forecast::TransferClassifierTest < ActiveSupport::TestCase
  # A fixed run date: classification here never depends on the calendar, so the
  # value is arbitrary — it just proves the threaded date is always supplied
  # rather than silently defaulting to the wall clock.
  RUN_DATE = Date.new(2024, 1, 15)

  test "call requires an explicit run date instead of defaulting to the wall clock" do
    classifier = Forecast::TransferClassifier.new(
      liquidity_classifier: Forecast::LiquidityClassifier.new(family: families(:dylan_family), scenario_ids: [])
    )

    assert_raises(ArgumentError) do
      classifier.call(source_account: accounts(:depository), destination_account: accounts(:credit_card), amount: 250)
    end
  end

  test "credit card payment is budget-neutral but reduces debt" do
    classifier = Forecast::TransferClassifier.new(
      liquidity_classifier: Forecast::LiquidityClassifier.new(family: families(:dylan_family), scenario_ids: [])
    )

    effect = classifier.call(source_account: accounts(:depository), destination_account: accounts(:credit_card), amount: 250, date: RUN_DATE)

    assert_equal "cc_payment", effect.fetch(:transaction_kind)
    assert_equal "none", effect.fetch(:budget_flow_type)
    assert_equal(-250.to_d, effect.fetch(:debt_delta))
    assert_equal 0.to_d, effect.fetch(:net_worth_delta)
  end

  test "debt payment from investment source reduces portfolio instead of assuming cash source" do
    classifier = Forecast::TransferClassifier.new(
      liquidity_classifier: Forecast::LiquidityClassifier.new(family: families(:dylan_family), scenario_ids: [])
    )

    effect = classifier.call(source_account: accounts(:investment), destination_account: accounts(:credit_card), amount: 250, date: RUN_DATE)

    assert_equal "cc_payment", effect.fetch(:transaction_kind)
    assert_equal "none", effect.fetch(:budget_flow_type)
    assert_equal 0.to_d, effect.fetch(:cash_delta)
    assert_equal(-250.to_d, effect.fetch(:portfolio_delta))
    assert_equal(-250.to_d, effect.fetch(:debt_delta))
    assert_equal 0.to_d, effect.fetch(:net_worth_delta)
  end

  test "investment to investment transfer is budget-neutral funds movement" do
    family = families(:dylan_family)
    other_investment = family.accounts.create!(
      name: "IRA rollover",
      balance: 5000,
      currency: family.currency,
      accountable: Investment.new
    )
    classifier = Forecast::TransferClassifier.new(
      liquidity_classifier: Forecast::LiquidityClassifier.new(family: family, scenario_ids: [])
    )

    effect = classifier.call(source_account: accounts(:investment), destination_account: other_investment, amount: 500, date: RUN_DATE)

    assert_equal "funds_movement", effect.fetch(:transaction_kind)
    assert_equal "none", effect.fetch(:budget_flow_type)
    assert_equal 0.to_d, effect.fetch(:expected_spending)
  end

  test "one-sided transfer out of scoped cash account reduces scoped net worth" do
    classifier = Forecast::TransferClassifier.new(
      liquidity_classifier: Forecast::LiquidityClassifier.new(family: families(:dylan_family), scenario_ids: []),
      included_account_ids: [ accounts(:depository).id ]
    )

    effect = classifier.call(source_account: accounts(:depository), destination_account: accounts(:investment), amount: 400, date: RUN_DATE)

    assert_equal "investment_contribution", effect.fetch(:transaction_kind)
    assert_equal "expense", effect.fetch(:budget_flow_type)
    assert_equal 400.to_d, effect.fetch(:expected_spending)
    assert_equal(-400.to_d, effect.fetch(:cash_delta))
    assert_equal(-400.to_d, effect.fetch(:liquid_delta))
    assert_equal 0.to_d, effect.fetch(:portfolio_delta)
    assert_equal(-400.to_d, effect.fetch(:net_worth_delta))
  end

  test "one-sided transfer into scoped cash account increases scoped net worth without income" do
    classifier = Forecast::TransferClassifier.new(
      liquidity_classifier: Forecast::LiquidityClassifier.new(family: families(:dylan_family), scenario_ids: []),
      included_account_ids: [ accounts(:depository).id ]
    )

    effect = classifier.call(source_account: accounts(:investment), destination_account: accounts(:depository), amount: 400, date: RUN_DATE)

    assert_equal "funds_movement", effect.fetch(:transaction_kind)
    assert_equal "none", effect.fetch(:budget_flow_type)
    assert_equal 0.to_d, effect.fetch(:expected_income)
    assert_equal 0.to_d, effect.fetch(:expected_spending)
    assert_equal 400.to_d, effect.fetch(:cash_delta)
    assert_equal 400.to_d, effect.fetch(:liquid_delta)
    assert_equal 400.to_d, effect.fetch(:net_worth_delta)
  end

  test "destination-only loan transfer is not a budget expense" do
    classifier = Forecast::TransferClassifier.new(
      liquidity_classifier: Forecast::LiquidityClassifier.new(family: families(:dylan_family), scenario_ids: []),
      included_account_ids: [ accounts(:loan).id ]
    )

    effect = classifier.call(source_account: accounts(:depository), destination_account: accounts(:loan), amount: 200, date: RUN_DATE)

    assert_equal "loan_payment", effect.fetch(:transaction_kind)
    assert_equal "none", effect.fetch(:budget_flow_type)
    assert_equal 0.to_d, effect.fetch(:expected_spending)
    assert_equal(-200.to_d, effect.fetch(:debt_delta))
    assert_equal 200.to_d, effect.fetch(:net_worth_delta)
  end

  test "same-scope cross-currency transfers use endpoint-specific converted amounts" do
    classifier = Forecast::TransferClassifier.new(
      liquidity_classifier: Forecast::LiquidityClassifier.new(family: families(:dylan_family), scenario_ids: []),
      included_account_ids: [ accounts(:depository).id, accounts(:loan).id ]
    )

    effect = classifier.call(source_account: accounts(:depository), destination_account: accounts(:loan), amount: 200, destination_amount: 180, date: RUN_DATE)

    assert_equal "loan_payment", effect.fetch(:transaction_kind)
    assert_equal 200.to_d, effect.fetch(:expected_spending)
    assert_equal(-200.to_d, effect.fetch(:cash_delta))
    assert_equal(-180.to_d, effect.fetch(:debt_delta))
    assert_equal(-20.to_d, effect.fetch(:net_worth_delta))
  end

  test "non-transfer income in a liquid investment account does not inflate cash" do
    classifier = Forecast::TransferClassifier.new(
      liquidity_classifier: Forecast::LiquidityClassifier.new(family: families(:dylan_family), scenario_ids: [])
    )

    effect = classifier.call(source_account: accounts(:investment), destination_account: nil, amount: -125, date: RUN_DATE)

    assert_equal "standard", effect.fetch(:transaction_kind)
    assert_equal "income", effect.fetch(:budget_flow_type)
    assert_equal 0.to_d, effect.fetch(:cash_delta)
    assert_equal 125.to_d, effect.fetch(:liquid_delta)
    assert_equal 125.to_d, effect.fetch(:portfolio_delta)
    assert_equal 125.to_d, effect.fetch(:net_worth_delta)
  end

  test "liability account expense increases debt instead of reducing cash" do
    classifier = Forecast::TransferClassifier.new(
      liquidity_classifier: Forecast::LiquidityClassifier.new(family: families(:dylan_family), scenario_ids: [])
    )

    effect = classifier.call(source_account: accounts(:credit_card), destination_account: nil, amount: 80, date: RUN_DATE)

    assert_equal "standard", effect.fetch(:transaction_kind)
    assert_equal "liability_charge", effect.fetch(:effect_label)
    assert_equal "expense", effect.fetch(:budget_flow_type)
    assert_equal 0.to_d, effect.fetch(:cash_delta)
    assert_equal 80.to_d, effect.fetch(:debt_delta)
    assert_equal(-80.to_d, effect.fetch(:net_worth_delta))
  end
end
