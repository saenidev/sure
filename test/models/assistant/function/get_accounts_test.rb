require "test_helper"

class Assistant::Function::GetAccountsTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @family = @user.family
    @fn = Assistant::Function::GetAccounts.new(@user)
  end

  test "has correct name" do
    assert_equal "get_accounts", @fn.name
  end

  test "has a description" do
    assert_not_empty @fn.description
  end

  test "is not in strict mode" do
    refute @fn.to_definition[:strict]
  end

  test "returns account ids and omits the balance series by default" do
    result = @fn.call

    assert result[:accounts].any?

    result[:accounts].each do |account|
      assert account[:id].present?
      assert_not account.key?(:historical_balances)
    end
  end

  test "excludes hidden accounts" do
    hidden = @family.accounts.visible.first
    hidden.update!(status: "disabled")

    result = @fn.call

    assert_not_includes result[:accounts].map { |a| a[:id] }, hidden.id
  end

  test "includes a balance series bounded by the requested period when asked" do
    result = @fn.call({ "include_balance_series" => true, "series_period" => "last_30_days" })

    account = result[:accounts].first
    series = account[:historical_balances]

    assert series.present?
    assert series[:start_date] >= 30.days.ago.to_date
    assert_equal Date.current, series[:end_date]
    assert(series[:values].all? { |v| v.is_a?(Numeric) })
  end

  test "falls back to last_365_days for an unknown series period" do
    result = @fn.call({ "include_balance_series" => true, "series_period" => "bogus" })

    series = result[:accounts].first[:historical_balances]

    assert series[:start_date] >= 366.days.ago.to_date
  end

  test "an account starting beyond the period skips its series without failing the call" do
    future_account = @family.accounts.create!(
      name: "Future Start Account",
      balance: 0,
      currency: "USD",
      accountable: Depository.new
    )
    future_account.entries.create!(
      name: "Scheduled opening deposit",
      date: 30.days.from_now.to_date,
      amount: -100,
      currency: "USD",
      entryable: Transaction.new
    )

    result = @fn.call({ "include_balance_series" => true, "series_period" => "last_7_days" })

    assert_not result.key?(:error)

    future_payload = result[:accounts].find { |a| a[:id] == future_account.id }

    assert_not_nil future_payload
    assert_not future_payload.key?(:historical_balances)
    assert(result[:accounts].any? { |a| a.key?(:historical_balances) })
  end

  test "a linked account reports its provider item's failed sync alongside the last completed sync time" do
    item = SimplefinItem.create!(family: @family, name: "SF Conn", access_url: "https://example.com/access")
    simplefin_account = SimplefinAccount.create!(
      simplefin_item: item,
      account_id: "ACT-sync-status",
      name: "Checking",
      currency: "USD",
      current_balance: 100,
      account_type: "checking"
    )
    account = @family.accounts.create!(
      name: "Linked Checking",
      balance: 100,
      currency: "USD",
      accountable: Depository.new
    )
    AccountProvider.create!(account: account, provider: simplefin_account)

    completed_at = Time.zone.parse("2026-09-22 02:00:00")
    Sync.create!(
      syncable: item,
      status: "completed",
      created_at: completed_at - 5.minutes,
      completed_at: completed_at
    )
    Sync.create!(
      syncable: item,
      status: "failed",
      created_at: Time.zone.parse("2026-09-24 02:00:00"),
      failed_at: Time.zone.parse("2026-09-24 02:01:00"),
      error: "Connection refused for https://user:s3cr3t@bridge.simplefin.org/simplefin/accounts " + ("x" * 300)
    )

    payload = @fn.call[:accounts].find { |a| a[:id] == account.id }

    assert_not_nil payload
    assert_equal "failed", payload[:last_sync_status]
    assert_equal completed_at.iso8601, payload[:last_synced_at]
    assert payload[:last_sync_error].present?
    assert_includes payload[:last_sync_error], "Connection refused"
    assert_not_includes payload[:last_sync_error], "s3cr3t"
    assert payload[:last_sync_error].length <= 200
  end

  test "a manual account reports no sync status" do
    manual = @family.accounts.create!(
      name: "Manual Cash",
      balance: 50,
      currency: "USD",
      accountable: Depository.new
    )

    payload = @fn.call[:accounts].find { |a| a[:id] == manual.id }

    assert_not_nil payload
    assert payload.key?(:last_synced_at)
    assert payload.key?(:last_sync_status)
    assert payload.key?(:last_sync_error)
    assert_nil payload[:last_synced_at]
    assert_nil payload[:last_sync_status]
    assert_nil payload[:last_sync_error]
  end
end
