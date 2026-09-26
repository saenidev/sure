require "test_helper"

class EntryTest < ActiveSupport::TestCase
  include EntriesTestHelper

  # Every destroy path (single delete, bulk delete, account deletion) goes
  # through Entry#destroy, so the restore lives on the model.
  test "destroying a trade created by converting a transaction restores the original" do
    original, trade_entry = converted_transaction_and_trade

    trade_entry.destroy!

    original.reload
    assert_equal 250, original.amount
    assert_not original.excluded?
    assert_not original.transaction.extra.key?("converted_to_trade")
    assert_equal "kept", original.transaction.extra["other"]
  end

  test "bulk-destroying a converted trade restores the original" do
    original, trade_entry = converted_transaction_and_trade

    original.account.entries.destroy_by(id: [ trade_entry.id ])

    assert_equal 250, original.reload.amount
    assert_not original.excluded?
  end

  test "destroying an unrelated trade leaves converted originals alone" do
    original, _trade_entry = converted_transaction_and_trade
    other_trade = create_trade(securities(:aapl), account: original.account, qty: 1, date: original.date, price: 10)

    other_trade.destroy!

    assert_equal 0, original.reload.amount
    assert original.excluded?
  end

  test "a converted original cannot be un-excluded while its trade exists" do
    original, _trade_entry = converted_transaction_and_trade

    assert_not original.update(excluded: false)
    assert_includes original.errors[:excluded], "cannot be toggled off for a transaction converted to a trade"
  end

  test "chronological ordering uses id as final tie breaker" do
    account = accounts(:depository)
    timestamp = Time.zone.parse("2026-05-05 12:00:00")

    entries = 3.times.map do |index|
      create_transaction(
        account: account,
        name: "Same timestamp transaction #{index}",
        date: Date.new(2026, 5, 5),
        created_at: timestamp,
        updated_at: timestamp
      )
    end

    entry_ids = entries.map(&:id)

    assert_equal entry_ids.sort, Entry.where(id: entry_ids).chronological.pluck(:id)
    assert_equal entry_ids.sort.reverse, Entry.where(id: entry_ids).reverse_chronological.pluck(:id)
  end

  test "bulk_update! touches the assigned category's last_used_at" do
    entry = create_transaction(account: accounts(:depository))
    category = categories(:income)
    assert_nil category.last_used_at

    Entry.where(id: entry.id).bulk_update!({ category_id: category.id })

    assert_not_nil category.reload.last_used_at
  end

  private
    def converted_transaction_and_trade
      account = accounts(:investment)
      original = create_transaction(account: account, name: "ETF purchase", amount: 250, date: 3.days.ago.to_date)
      trade_entry = create_trade(securities(:aapl), account: account, qty: 5, date: original.date, price: 50)
      original.transaction.update!(extra: {
        "other" => "kept",
        "converted_to_trade" => { "trade_entry_id" => trade_entry.id, "original_amount" => "250.0" }
      })
      original.update!(excluded: true, amount: 0)
      [ original, trade_entry ]
    end
end
