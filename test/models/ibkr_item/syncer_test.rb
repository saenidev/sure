require "test_helper"

class IbkrItem::SyncerTest < ActiveSupport::TestCase
  fixtures :families, :ibkr_items, :ibkr_accounts, :accounts

  setup do
    @ibkr_item = ibkr_items(:configured_item)
  end

  test "perform_sync records a single auth error when credentials are missing" do
    @ibkr_item.update!(token: nil)
    syncer = IbkrItem::Syncer.new(@ibkr_item)
    sync = @ibkr_item.syncs.create!

    error = assert_raises(Provider::IbkrFlex::ConfigurationError) do
      syncer.perform_sync(sync)
    end

    assert_equal "IBKR credentials are missing.", error.message
    assert_equal "requires_update", @ibkr_item.reload.status

    stats = sync.reload.sync_stats
    assert_equal 1, stats["total_errors"]
    assert_equal [ { "message" => "IBKR credentials are missing.", "category" => "auth_error" } ], stats["errors"]
  end

  test "perform_sync records warning when flex data has cash but no positions or trades" do
    ibkr_account = ibkr_accounts(:main_account)
    ibkr_account.ensure_account_provider!(accounts(:investment))
    ibkr_account.update!(
      cash_balance: BigDecimal("1000.50"),
      raw_cash_report_payload: [ { "currency" => "BASE_SUMMARY", "ending_cash" => "1000.50" } ],
      raw_holdings_payload: [],
      raw_activities_payload: { trades: [], cash_transactions: [] }
    )

    @ibkr_item.stubs(:import_latest_ibkr_data)
    @ibkr_item.stubs(:process_accounts)
    @ibkr_item.stubs(:schedule_account_syncs)

    sync = @ibkr_item.syncs.create!

    IbkrItem::Syncer.new(@ibkr_item).perform_sync(sync)

    stats = sync.reload.sync_stats
    assert_equal 1, stats["data_warnings"]
    assert_match "cash balances but no open positions or trades", stats.dig("data_quality_details", 0, "message")
  end
end
