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

  test "perform_sync records ibkr raw and processed import counts" do
    ibkr_account = ibkr_accounts(:main_account)
    ibkr_account.ensure_account_provider!(accounts(:investment))
    ibkr_account.update!(
      raw_holdings_payload: [
        { "asset_category" => "STK", "symbol" => "AAPL", "quantity" => "8", "mark_price" => "152.50", "currency" => "USD" }
      ],
      raw_activities_payload: {
        trades: [
          { "asset_category" => "STK", "transaction_id" => "tx-1006", "symbol" => "AAPL", "quantity" => "5", "trade_price" => "149.00", "currency" => "USD", "buy_sell" => "BUY" }
        ],
        cash_transactions: []
      },
      raw_cash_report_payload: [ { "currency" => "BASE_SUMMARY", "ending_cash" => "1000.50" } ]
    )

    @ibkr_item.stubs(:import_latest_ibkr_data)
    @ibkr_item.stubs(:schedule_account_syncs)

    sync = @ibkr_item.syncs.create!

    IbkrItem::Syncer.new(@ibkr_item).perform_sync(sync)

    stats = sync.reload.sync_stats
    import = stats["ibkr_account_imports"].first

    assert_equal 1, stats["ibkr_raw_holdings_rows"]
    assert_equal 1, stats["ibkr_raw_trade_rows"]
    assert_equal 1, stats["ibkr_holdings_imported"]
    assert_equal 1, stats["ibkr_trades_imported"]
    assert_equal 1, import["raw_holdings_rows"]
    assert_equal 1, import["raw_trade_rows"]
    assert_equal 1, import["holdings_imported"]
    assert_equal 1, import["trades_imported"]
  end

  test "perform_sync warns when ibkr rows are present but not imported" do
    ibkr_account = ibkr_accounts(:main_account)
    ibkr_account.ensure_account_provider!(accounts(:investment))
    ibkr_account.update!(
      raw_holdings_payload: [
        { "asset_category" => "OPT", "symbol" => "AAPL", "quantity" => "1", "mark_price" => "1.00", "currency" => "USD" }
      ],
      raw_activities_payload: {
        trades: [
          { "asset_category" => "OPT", "transaction_id" => "tx-opt", "symbol" => "AAPL", "quantity" => "1", "trade_price" => "1.00", "currency" => "USD", "buy_sell" => "BUY" }
        ],
        cash_transactions: []
      }
    )

    @ibkr_item.stubs(:import_latest_ibkr_data)
    @ibkr_item.stubs(:schedule_account_syncs)

    sync = @ibkr_item.syncs.create!

    IbkrItem::Syncer.new(@ibkr_item).perform_sync(sync)

    details = sync.reload.sync_stats["data_quality_details"].map { |detail| detail["message"] }

    assert details.any? { |message| message.include?("Open Positions rows but imported 0 holdings") }
    assert details.any? { |message| message.include?("Trades rows but imported 0 trades") }
  end
end
