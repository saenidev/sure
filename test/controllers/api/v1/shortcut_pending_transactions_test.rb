# frozen_string_literal: true

require "test_helper"

# Live pending purchases from iPhone Shortcuts: POST /api/v1/transactions with
# pending: true, folding a tap and an alert into one entry, and settling against
# the bank's posted transaction from a real SimpleFIN import (only SimpleFIN's
# HTTP is stubbed).
class Api::V1::ShortcutPendingTransactionsTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  SIMPLEFIN_ACCESS_URL = "https://bridge.example.com/simplefin/access"

  setup do
    travel_to Time.zone.parse("2026-10-12 12:00:00 UTC")

    @user = users(:family_admin)
    @family = @user.family
    @account = accounts(:credit_card)

    @user.api_keys.active.destroy_all
    @phone_key = ApiKey.create!(
      user: @user,
      name: "iPhone Shortcuts",
      scopes: [ "read_write" ],
      display_key: "test_phone_#{SecureRandom.hex(8)}"
    )
    @reader_key = ApiKey.create!(
      user: @user,
      name: "antidegen",
      scopes: [ "read" ],
      display_key: "test_reader_#{SecureRandom.hex(8)}",
      source: "mobile"
    )
    Redis.new.del("api_rate_limit:#{@phone_key.id}")
    Redis.new.del("api_rate_limit:#{@reader_key.id}")

    @simplefin_item = SimplefinItem.create!(family: @family, name: "Chase via SimpleFIN", access_url: SIMPLEFIN_ACCESS_URL)
    @simplefin_account = SimplefinAccount.create!(
      simplefin_item: @simplefin_item,
      name: "Chase Sapphire",
      account_id: "sf_chase",
      account_type: "credit",
      currency: "USD",
      current_balance: -500,
      available_balance: 0
    )
    @account.update!(simplefin_account_id: @simplefin_account.id)
  end

  teardown do
    travel_back
  end

  # --- Creating pending entries -------------------------------------------

  test "pending POST creates one pending entry that stays out of the income statement" do
    expenses_before = expense_total

    assert_difference -> { @account.entries.count }, 1 do
      post_pending(client_id: "tap-1", origin: "apple_pay", name: "Blue Bottle Coffee", amount: "6.50",
                   occurred_at: "2026-10-12T08:15:00-04:00")
    end

    assert_response :created
    json = response.parsed_body
    assert_equal true, json["pending"]
    assert_equal false, json["excluded"]
    assert_equal "shortcut", json["source"]
    assert_equal "tap-1", json["external_id"]
    assert_equal 650, json["amount_cents"]
    assert_equal "pending", json.dig("shortcut", "status")
    assert_equal [ "apple_pay" ], json.dig("shortcut", "origins")
    assert_equal "2026-10-12T08:15:00-04:00", json.dig("shortcut", "occurred_at")

    entry = Transaction.find(json["id"]).entry
    assert entry.transaction.pending?
    assert_not entry.linked?, "a Shortcut hint must stay editable in the UI"
    assert_not entry.cleared?
    assert_equal expenses_before, expense_total
  end

  test "retrying the same client_id returns the existing entry" do
    post_pending(client_id: "tap-retry", origin: "apple_pay", name: "Blue Bottle Coffee", amount: "6.50",
                 occurred_at: "2026-10-12T08:15:00-04:00")
    assert_response :created
    first_id = response.parsed_body["id"]

    assert_no_difference -> { @account.entries.count } do
      post_pending(client_id: "tap-retry", origin: "apple_pay", name: "Blue Bottle Coffee", amount: "6.50",
                   occurred_at: "2026-10-12T08:15:00-04:00")
    end

    assert_response :ok
    assert_equal first_id, response.parsed_body["id"]
  end

  test "an alert and a tap 5 minutes apart fold into one entry" do
    post_pending(client_id: "alert-1", origin: "bank_alert", name: "STARBUCKS STORE 12345", amount: "6.75",
                 occurred_at: "2026-10-12T08:20:00-04:00")
    assert_response :created
    first_id = response.parsed_body["id"]

    assert_no_difference -> { @account.entries.count } do
      post_pending(client_id: "tap-2", origin: "apple_pay", name: "Starbucks", amount: "6.75",
                   occurred_at: "2026-10-12T08:15:00-04:00")
    end

    assert_response :ok
    json = response.parsed_body
    assert_equal first_id, json["id"]
    assert_equal "Starbucks", json["name"], "the Apple Pay merchant name wins"
    assert_equal [ "bank_alert", "apple_pay" ], json.dig("shortcut", "origins")
    assert_equal "2026-10-12T08:15:00-04:00", json.dig("shortcut", "occurred_at"), "the earlier time is kept"

    # A retry of the folded hint's own client_id finds the surviving entry.
    post_pending(client_id: "tap-2", origin: "apple_pay", name: "Starbucks", amount: "6.75",
                 occurred_at: "2026-10-12T08:15:00-04:00")
    assert_response :ok
    assert_equal first_id, response.parsed_body["id"]
  end

  test "a converted tap takes the bank alert's amount when they fold" do
    ExchangeRate.create!(from_currency: "KRW", to_currency: "USD", date: Date.new(2026, 10, 12), rate: 0.00074)

    post_pending(client_id: "tap-krw", origin: "apple_pay", name: "Cafe Onion", amount: "12000", currency: "KRW",
                 occurred_at: "2026-10-12T21:00:00+09:00")
    assert_response :created
    assert_equal 888, response.parsed_body["amount_cents"]

    post_pending(client_id: "alert-krw", origin: "bank_alert", name: "CAFE ONION SEOUL", amount: "9.02",
                 occurred_at: "2026-10-12T21:03:00+09:00")
    assert_response :ok
    json = response.parsed_body
    assert_equal "Cafe Onion", json["name"]
    assert_equal 902, json["amount_cents"]
    assert_equal "12000.0", json.dig("shortcut", "original_amount")
    assert_equal "KRW", json.dig("shortcut", "original_currency")
    assert_equal "provided", json.dig("shortcut", "conversion")
  end

  test "the same purchase two hours apart stays two entries" do
    post_pending(client_id: "tap-a", origin: "apple_pay", name: "Starbucks", amount: "6.75",
                 occurred_at: "2026-10-12T08:15:00-04:00")
    assert_response :created

    assert_difference -> { @account.entries.count }, 1 do
      post_pending(client_id: "alert-b", origin: "bank_alert", name: "STARBUCKS STORE 12345", amount: "6.75",
                   occurred_at: "2026-10-12T10:15:00-04:00")
    end
    assert_response :created
  end

  test "two taps minutes apart are two purchases" do
    post_pending(client_id: "tap-c1", origin: "apple_pay", name: "Starbucks", amount: "6.75",
                 occurred_at: "2026-10-12T08:15:00-04:00")
    assert_difference -> { @account.entries.count }, 1 do
      post_pending(client_id: "tap-c2", origin: "apple_pay", name: "Starbucks", amount: "6.75",
                   occurred_at: "2026-10-12T08:18:00-04:00")
    end
    assert_response :created
  end

  test "a foreign amount without an exchange rate is still recorded, flagged unconverted" do
    ExchangeRate.stubs(:provider).returns(nil) # no rate provider configured

    post_pending(client_id: "tap-norate", origin: "apple_pay", name: "Cafe Onion", amount: "12000", currency: "KRW",
                 occurred_at: "2026-10-12T21:00:00+09:00")

    assert_response :created
    json = response.parsed_body
    assert_equal "KRW", json["currency"]
    assert_equal true, json["pending"]
    assert_equal "unconverted", json.dig("shortcut", "conversion")
  end

  # --- Settling against SimpleFIN -------------------------------------------

  test "a SimpleFIN posted import settles the pending entry exactly, linked both ways" do
    pending_id = create_pending!(client_id: "tap-exact", name: "Blue Bottle Coffee", amount: "6.50",
                                 occurred_at: "2026-10-11T08:15:00-04:00")

    simplefin_sync!(posted_tx("sf_exact", "-6.50", "BLUE BOTTLE COFFEE", Date.new(2026, 10, 11)))

    assert_settled(pending_id, match: "exact", amount: BigDecimal("6.50"))
  end

  test "a posting dated one day before the tap settles it (tap in Korea, US posting date)" do
    pending_id = create_pending!(client_id: "tap-korea", name: "Olive Young", amount: "23.10",
                                 occurred_at: "2026-10-12T09:30:00+09:00")
    assert_equal "2026-10-12", get_transaction(pending_id)["date"]

    simplefin_sync!(posted_tx("sf_korea", "-23.10", "OLIVEYOUNG SEOUL", Date.new(2026, 10, 11)))

    assert_settled(pending_id, match: "exact", amount: BigDecimal("23.10"))
  end

  test "a tipped posting settles its single matching pending entry" do
    pending_id = create_pending!(client_id: "tap-tip", name: "Joe's Diner", amount: "40.00",
                                 occurred_at: "2026-10-10T19:30:00-04:00")

    simplefin_sync!(posted_tx("sf_tip", "-48.00", "JOES DINER #12", Date.new(2026, 10, 11)))

    assert_settled(pending_id, match: "tip", amount: BigDecimal("48.00"))
  end

  test "a KRW tap converted to USD settles against the USD posting within FX tolerance" do
    ExchangeRate.create!(from_currency: "KRW", to_currency: "USD", date: Date.new(2026, 10, 11), rate: 0.00074)

    pending_id = create_pending!(client_id: "tap-fx", name: "Cafe Onion", amount: "12000", currency: "KRW",
                                 occurred_at: "2026-10-11T21:00:00+09:00")
    assert_equal 888, get_transaction(pending_id)["amount_cents"]

    simplefin_sync!(posted_tx("sf_fx", "-9.14", "CAFE ONION SEOUL", Date.new(2026, 10, 11)))

    assert_settled(pending_id, match: "fx", amount: BigDecimal("9.14"))
  end

  test "the purchase counts once when SimpleFIN also delivered its own pending version" do
    pending_id = create_pending!(client_id: "tap-double", name: "Trader Joe's", amount: "31.42",
                                 occurred_at: "2026-10-10T17:05:00-04:00")

    simplefin_sync!(posted_tx("sf_pend", "-31.42", "TRADER JOE S #552", Date.new(2026, 10, 10), pending: true))
    assert_equal "pending", get_transaction(pending_id).dig("shortcut", "status"),
      "a bank pending entry is not the posted version"

    simplefin_sync!(posted_tx("sf_posted", "-31.42", "TRADER JOE S #552", Date.new(2026, 10, 11)))

    assert_settled(pending_id, match: "exact", amount: BigDecimal("31.42"))
  end

  test "a posting that arrived before the hint settles it on creation" do
    simplefin_sync!(posted_tx("sf_early", "-12.00", "CHIPOTLE 1234", Date.new(2026, 10, 11)))

    post_pending(client_id: "alert-late", origin: "bank_alert", name: "CHIPOTLE 1234", amount: "12.00",
                 occurred_at: "2026-10-11T12:30:00-04:00")
    assert_response :created
    assert_equal "settled", response.parsed_body.dig("shortcut", "status")
  end

  test "two same-amount purchases on one day are never cross-settled" do
    starbucks_id = create_pending!(client_id: "tap-sb", name: "Starbucks", amount: "5.00",
                                   occurred_at: "2026-10-11T08:00:00-04:00")
    blue_bottle_id = create_pending!(client_id: "tap-bb", name: "Blue Bottle Coffee", amount: "5.00",
                                     occurred_at: "2026-10-11T15:00:00-04:00")

    # Only one of the two has posted: it must settle its own hint, not the other.
    simplefin_sync!(posted_tx("sf_bb", "-5.00", "BLUE BOTTLE COFFEE", Date.new(2026, 10, 11)))

    assert_equal "settled", get_transaction(blue_bottle_id).dig("shortcut", "status")
    assert_equal "pending", get_transaction(starbucks_id).dig("shortcut", "status")
  end

  test "identical purchases that cannot be told apart stay pending" do
    first_id = create_pending!(client_id: "tap-same-1", name: "Starbucks", amount: "5.00",
                               occurred_at: "2026-10-11T08:00:00-04:00")
    second_id = create_pending!(client_id: "tap-same-2", name: "Starbucks", amount: "5.00",
                                occurred_at: "2026-10-11T09:00:00-04:00")

    simplefin_sync!(posted_tx("sf_same_1", "-5.00", "STARBUCKS", Date.new(2026, 10, 11)))

    assert_equal "pending", get_transaction(first_id).dig("shortcut", "status")
    assert_equal "pending", get_transaction(second_id).dig("shortcut", "status")
  end

  # --- Reading changes --------------------------------------------------------

  test "updated_since returns the flip from pending to settled" do
    pending_id = create_pending!(client_id: "tap-poll", name: "Blue Bottle Coffee", amount: "6.50",
                                 occurred_at: "2026-10-11T08:15:00-04:00")

    travel 10.minutes
    since = Time.current.iso8601

    get api_v1_transactions_url, params: { updated_since: since }, headers: api_headers(@reader_key)
    assert_response :success
    assert_empty response.parsed_body["transactions"]

    travel 1.minute
    simplefin_sync!(posted_tx("sf_poll", "-6.50", "BLUE BOTTLE COFFEE", Date.new(2026, 10, 11)))

    get api_v1_transactions_url, params: { updated_since: since }, headers: api_headers(@reader_key)
    assert_response :success
    rows = response.parsed_body["transactions"].index_by { |row| row["id"] }

    pending_row = rows.fetch(pending_id)
    assert_equal "settled", pending_row.dig("shortcut", "status")
    assert_equal false, pending_row["pending"]
    assert_equal true, pending_row["excluded"]

    posted_id = pending_row.dig("shortcut", "settled_by_transaction_id")
    assert_equal pending_id, rows.fetch(posted_id).dig("shortcut", "matched_pending_transaction_id")
  end

  test "updated_since must be an ISO 8601 timestamp" do
    get api_v1_transactions_url, params: { updated_since: "yesterday" }, headers: api_headers(@reader_key)

    assert_response :unprocessable_entity
    assert_equal "validation_failed", response.parsed_body["error"]
  end

  # --- Validation and authorization -------------------------------------------

  test "a pending POST needs client_id, origin and an occurred_at with offset" do
    post api_v1_transactions_url,
      params: { transaction: { account_id: @account.id, pending: true, name: "Starbucks", amount: "5.00",
                               origin: "carrier_pigeon", occurred_at: "2026-10-12T08:00:00" } },
      headers: api_headers(@phone_key)

    assert_response :unprocessable_entity
    errors = response.parsed_body["errors"].join(" ")
    assert_match "Client", errors
    assert_match "Origin", errors
    assert_match "Occurred at", errors
  end

  test "a read-only key cannot post pending purchases" do
    post_pending(client_id: "tap-ro", origin: "apple_pay", name: "Starbucks", amount: "5.00",
                 occurred_at: "2026-10-12T08:00:00-04:00", key: @reader_key)

    assert_response :forbidden
  end

  test "the shortcut source is reserved for pending hints" do
    post api_v1_transactions_url,
      params: { transaction: { account_id: @account.id, name: "Starbucks", amount: "5.00", date: "2026-10-12",
                               source: "shortcut", external_id: "sneaky" } },
      headers: api_headers(@phone_key)

    assert_response :unprocessable_entity
  end

  test "the manual merge settles a Shortcut entry instead of deleting it" do
    pending_id = create_pending!(client_id: "tap-manual", name: "Parking", amount: "10.00",
                                 occurred_at: "2026-10-11T08:00:00-04:00")
    simplefin_sync!(posted_tx("sf_manual", "-17.00", "LAZ PARKING 991", Date.new(2026, 10, 11)))
    assert_equal "pending", get_transaction(pending_id).dig("shortcut", "status"), "no automatic match"

    pending_entry = Transaction.find(pending_id).entry
    posted_entry = @account.entries.find_by!(source: "simplefin", external_id: "simplefin_sf_manual")

    sign_in @user
    assert_no_difference -> { Entry.count } do
      post transaction_pending_duplicate_merges_path(pending_entry),
        params: { pending_duplicate_merges: { posted_entry_id: posted_entry.id } }
    end

    json = get_transaction(pending_id)
    assert_equal "settled", json.dig("shortcut", "status")
    assert_equal "manual", json.dig("shortcut", "settlement_match")
    assert_equal posted_entry.entryable_id, json.dig("shortcut", "settled_by_transaction_id")
  end

  private

    def post_pending(client_id:, origin:, name:, amount:, occurred_at:, currency: nil, key: @phone_key)
      post api_v1_transactions_url,
        params: { transaction: {
          account_id: @account.id, pending: true, client_id: client_id, origin: origin,
          name: name, amount: amount, currency: currency, occurred_at: occurred_at
        }.compact },
        headers: api_headers(key)
    end

    def create_pending!(client_id:, name:, amount:, occurred_at:, currency: nil)
      post_pending(client_id: client_id, origin: "apple_pay", name: name, amount: amount,
                   currency: currency, occurred_at: occurred_at)
      assert_response :created
      response.parsed_body["id"]
    end

    def get_transaction(id)
      get api_v1_transaction_url(id), headers: api_headers(@reader_key)
      assert_response :success
      response.parsed_body
    end

    # SimpleFIN sends epochs; noon UTC keeps the calendar date in any time zone.
    def posted_tx(id, amount, payee, posted_on, pending: false)
      epoch = Time.utc(posted_on.year, posted_on.month, posted_on.day, 12).to_i
      {
        id: id,
        amount: amount,
        currency: "USD",
        payee: payee,
        description: payee,
        memo: "",
        posted: pending ? 0 : epoch,
        transacted_at: epoch,
        pending: pending
      }
    end

    # Runs a real SimpleFIN sync (import, processing, then the account sync
    # it schedules) against a stubbed SimpleFIN bridge.
    def simplefin_sync!(*transactions)
      body = {
        errors: [],
        accounts: [ {
          id: "sf_chase",
          name: "Chase Sapphire",
          currency: "USD",
          balance: "-500.00",
          "available-balance": "0.00",
          "balance-date": Time.current.to_i,
          org: { name: "Chase", domain: "chase.com" },
          transactions: transactions
        } ]
      }
      stub_request(:get, %r{\A#{Regexp.escape(SIMPLEFIN_ACCESS_URL)}/accounts})
        .to_return(status: 200, body: body.to_json, headers: { "Content-Type" => "application/json" })

      Sync.create!(syncable: @simplefin_item).perform
      perform_enqueued_jobs
    end

    def assert_settled(pending_id, match:, amount:)
      pending_json = get_transaction(pending_id)
      assert_equal "settled", pending_json.dig("shortcut", "status")
      assert_equal match, pending_json.dig("shortcut", "settlement_match")
      assert_equal false, pending_json["pending"]
      assert_equal true, pending_json["excluded"]

      posted_id = pending_json.dig("shortcut", "settled_by_transaction_id")
      assert posted_id.present?
      posted_json = get_transaction(posted_id)
      assert_equal pending_id, posted_json.dig("shortcut", "matched_pending_transaction_id")
      assert_equal "simplefin", posted_json["source"]
      assert_equal false, posted_json["pending"]

      pending_entry = Transaction.find(pending_id).entry
      assert_equal posted_json["shortcut"]["matched_pending_entry_id"], pending_entry.id
      assert_equal pending_entry.transaction.extra.dig("shortcut", "settled_by_entry_id"),
        Transaction.find(posted_id).entry.id

      counted = @account.entries.where(excluded: false).excluding_pending
                        .where("ABS(entries.amount) = ?", amount)
      assert_equal 1, counted.count, "exactly one counted transaction for the purchase"
    end

    def expense_total
      IncomeStatement.new(@family).expense_totals(period: Period.current_month).total
    end
end
