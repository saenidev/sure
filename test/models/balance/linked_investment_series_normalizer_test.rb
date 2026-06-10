require "test_helper"

class Balance::LinkedInvestmentSeriesNormalizerTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @account = @family.accounts.create!(
      name: "Linked Brokerage",
      balance: 10_000,
      cash_balance: 500,
      currency: "USD",
      accountable: Investment.new
    )
    @account_provider = AccountProvider.create!(account: @account, provider: plaid_accounts(:one))
    @security = Security.create!(ticker: "TEST", name: "Test Security")
  end

  test "trims fabricated history for linked investment account without trades" do
    create_provider_transaction(date: 20.days.ago.to_date)
    create_provider_holding(date: 1.day.ago.to_date)
    create_provider_holding(date: Date.current)

    normalized = Balance::LinkedInvestmentSeriesNormalizer.new(account: @account, series: month_series).normalize

    # Without trades, holdings cannot be reconstructed before the stable
    # provider snapshot window, so earlier (fabricated) values must be cut.
    assert_equal 1.day.ago.to_date, normalized.values.first.date
  end

  test "keeps transaction-era history when account has trade entries" do
    create_provider_transaction(date: 20.days.ago.to_date)
    create_trade(date: 20.days.ago.to_date)
    create_provider_holding(date: 1.day.ago.to_date)
    create_provider_holding(date: Date.current)

    normalized = Balance::LinkedInvestmentSeriesNormalizer.new(account: @account, series: month_series).normalize

    assert_equal 20.days.ago.to_date, normalized.values.first.date
  end

  test "falls back to first activity date when account has no provider holdings" do
    create_provider_transaction(date: 20.days.ago.to_date)

    normalized = Balance::LinkedInvestmentSeriesNormalizer.new(account: @account, series: month_series).normalize

    assert_equal 20.days.ago.to_date, normalized.values.first.date
  end

  test "aggregate trim uses stable holdings window for trade-less accounts" do
    create_provider_transaction(date: 20.days.ago.to_date)
    create_provider_holding(date: 1.day.ago.to_date)
    create_provider_holding(date: Date.current)

    series = Balance::LinkedInvestmentSeriesNormalizer.aggregate_account_ids(
      account_ids: [ @account.id ],
      currency: "USD",
      period: Period.last_30_days,
      favorable_direction: "up"
    )

    assert series.values.all? { |v| v.date >= 1.day.ago.to_date }
  end

  test "clamps trim date to series end when stable window starts after it" do
    create_provider_transaction(date: 20.days.ago.to_date)
    # Future-dated provider row (artifact of older code): stable window would
    # start after the series ends, which must not fall back to fabricated history.
    create_provider_holding(date: Date.current + 1.day)

    normalized = Balance::LinkedInvestmentSeriesNormalizer.new(account: @account, series: month_series).normalize

    assert_equal [ Date.current ], normalized.values.map(&:date)
  end

  private

    def month_series
      Series.from_raw_values(
        (0..30).to_a.reverse.map { |n| { date: n.days.ago.to_date, value: 100 + n } }
      )
    end

    def create_provider_transaction(date:)
      @account.entries.create!(
        name: "Buy something",
        date: date,
        amount: 100,
        currency: "USD",
        source: "simplefin",
        entryable: Transaction.new
      )
    end

    def create_trade(date:)
      @account.entries.create!(
        name: "Buy TEST",
        date: date,
        amount: 100,
        currency: "USD",
        source: "simplefin",
        entryable: Trade.new(security: @security, qty: 1, price: 100, currency: "USD")
      )
    end

    def create_provider_holding(date:)
      @account.holdings.create!(
        security: @security,
        date: date,
        qty: 10,
        price: 100,
        amount: 1000,
        currency: "USD",
        account_provider: @account_provider
      )
    end
end
