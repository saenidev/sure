require "test_helper"

class Assistant::Function::GetTransactionsTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @transaction = transactions(:one)
    @function = Assistant::Function::GetTransactions.new(@user)
  end

  test "returns transaction ids and notes" do
    @transaction.entry.update!(notes: "Visible note")

    result = @function.call(
      "page" => 1,
      "order" => "asc",
      "search" => @transaction.entry.name
    )

    transaction = result[:transactions].find { |item| item[:id] == @transaction.id }

    assert_not_nil transaction
    assert_equal @transaction.entry.notes, transaction[:notes]
  end

  test "excludes transactions from inaccessible accounts" do
    hidden_entry = Entry.create!(
      account: accounts(:investment),
      name: "Private investment transaction",
      date: Date.current,
      amount: 100,
      currency: "USD",
      entryable: Transaction.new
    )
    hidden_entry.update!(notes: "Private note")

    result = Assistant::Function::GetTransactions.new(users(:family_member)).call(
      "page" => 1,
      "order" => "asc",
      "search" => hidden_entry.name
    )

    assert_empty result[:transactions]
  end

  test "translates the documented Uncategorized category alias to the filter sentinel" do
    uncategorized_entry = Entry.create!(
      account: accounts(:depository),
      name: "AI uncategorized lookup",
      date: Date.current,
      amount: 42,
      currency: "USD",
      entryable: Transaction.new
    )

    result = @function.call("categories" => [ "Uncategorized" ])
    result_ids = result[:transactions].map { |t| t[:id] }

    assert_includes result_ids, uncategorized_entry.entryable.id
  end

  test "a real category literally named Uncategorized takes priority over the alias translation" do
    family = @user.family
    lookalike_category = family.categories.create!(name: "Uncategorized", color: "#123456")

    lookalike_entry = Entry.create!(
      account: accounts(:depository),
      name: "AI lookalike category lookup",
      date: Date.current,
      amount: 42,
      currency: "USD",
      entryable: Transaction.new(category: lookalike_category)
    )

    truly_uncategorized_entry = Entry.create!(
      account: accounts(:depository),
      name: "AI truly uncategorized lookup",
      date: Date.current,
      amount: 42,
      currency: "USD",
      entryable: Transaction.new
    )

    result = @function.call("categories" => [ "Uncategorized" ])
    result_ids = result[:transactions].map { |t| t[:id] }

    assert_includes result_ids, lookalike_entry.entryable.id
    assert_not_includes result_ids, truly_uncategorized_entry.entryable.id
  end

  test "schema no longer inlines user data enums" do
    schema = @function.params_schema

    %i[accounts categories merchants tags].each do |key|
      items = schema[:properties][key][:items]

      assert_equal({ type: "string" }, items, "#{key} should be a plain string array")
    end
  end

  test "honors page_size" do
    result = @function.call("page_size" => 1)

    assert_equal 1, result[:page_size]
    assert_equal 1, result[:transactions].size
    assert result[:total_pages] > 1
  end

  test "sorts by absolute amount" do
    result = @function.call("sort_by" => "amount", "order" => "desc")

    amounts = result[:transactions].map { |t| t[:amount].abs }

    assert_equal amounts.sort.reverse, amounts
  end

  test "filters by type" do
    result = @function.call("types" => [ "income" ])

    assert result[:transactions].any?
    assert result[:transactions].all? { |t| t[:classification] == "income" }
  end

  test "filters by account_ids and ignores inaccessible ids" do
    accessible_account = @transaction.entry.account

    result = @function.call("account_ids" => [ accessible_account.id ])

    assert result[:transactions].any?
    assert result[:transactions].all? { |t| t[:account] == accessible_account.name }

    member_result = Assistant::Function::GetTransactions.new(users(:family_member)).call(
      "account_ids" => [ accounts(:investment).id ]
    )

    assert_empty member_result[:transactions]
  end

  # Composed reports (one-time windfalls, a transfer audit) need one kind, not a
  # whole year of transactions paged through the API.
  test "kinds filter narrows results to those transaction kinds" do
    @transaction.update!(kind: "one_time")

    result = @function.call("kinds" => [ "one_time" ])

    assert_includes result[:transactions].map { |t| t[:id] }, @transaction.id
    assert result[:transactions].all? { |t| t[:kind] == "one_time" }
    assert_operator result[:total_results], :<, @function.call({})[:total_results]
  end

  # A misspelled kind used to match nothing, so a report showed "no one-time
  # items" instead of telling the caller the filter was wrong.
  test "unknown kinds are named instead of silently matching nothing" do
    result = @function.call("kinds" => [ "onetime", "one_time" ])

    assert_equal "Unknown transaction kind(s): onetime", result[:error]
    assert_equal Transaction.kinds.keys, result[:valid_kinds]
  end

  test "kinds and types combine as AND" do
    @transaction.update!(kind: "one_time")

    result = @function.call("kinds" => [ "one_time" ], "types" => [ "transfer" ])

    assert_not_includes result[:transactions].map { |t| t[:id] }, @transaction.id
  end

  # is_transfer alone could not tell a card payment from an investment move or a
  # one-time windfall, so callers could not separate real spending and income
  # from money moving between the user's own accounts.
  test "each transaction reports its kind" do
    @transaction.update!(kind: "one_time")

    result = @function.call("search" => @transaction.entry.name)
    item = result[:transactions].find { |t| t[:id] == @transaction.id }

    assert_equal "one_time", item[:kind]
    assert result[:transactions].all? { |t| Transaction.kinds.key?(t[:kind]) }
  end

  # A broker trade imported as a cash row and relabelled Buy/Sell is kind
  # funds_movement like a real transfer; without the label a caller cannot
  # tell it apart from a transfer that lost its other side.
  test "each transaction reports its investment activity label" do
    @transaction.update!(kind: "funds_movement", investment_activity_label: "Buy")

    result = @function.call("search" => @transaction.entry.name)
    item = result[:transactions].find { |t| t[:id] == @transaction.id }

    assert_equal "Buy", item[:investment_activity_label]
  end

  # is_transfer only reflects kind, so a card refund kinded cc_payment with no
  # counterpart looked the same as a real payment between two accounts.
  test "each transaction reports whether it is a leg of a real transfer" do
    linked = transactions(:transfer_out)
    unlinked = @transaction
    unlinked.update!(kind: "cc_payment")

    items = @function.call("page_size" => 100)[:transactions].index_by { |t| t[:id] }

    assert_equal true, items[linked.id][:has_transfer_link]
    assert_equal true, items[transactions(:transfer_in).id][:has_transfer_link]
    assert_equal false, items[unlinked.id][:has_transfer_link]
    assert_equal true, items[unlinked.id][:is_transfer]
  end

  test "each transaction reports whether the user has modified it" do
    @transaction.entry.update!(user_modified: true)

    items = @function.call("page_size" => 100)[:transactions].index_by { |t| t[:id] }

    assert_equal true, items[@transaction.id][:user_modified]
    assert_equal false, items[transactions(:transfer_out).id][:user_modified]
  end

  test "each transaction reports its locked attributes from both the transaction and its entry" do
    @transaction.lock_attr!(:kind)
    @transaction.lock_attr!(:category_id)
    @transaction.entry.lock_attr!(:name)

    items = @function.call("page_size" => 100)[:transactions].index_by { |t| t[:id] }

    assert_equal %w[category_id kind name], items[@transaction.id][:locked]
    assert_equal [], items[transactions(:transfer_out).id][:locked]
  end

  test "each transaction reports its account type" do
    items = @function.call("page_size" => 100)[:transactions].index_by { |t| t[:id] }

    assert_equal "Depository", items[transactions(:transfer_out).id][:account_type]
    assert_equal "CreditCard", items[transactions(:transfer_in).id][:account_type]
  end

  # Search returns rows the user hid from reports (stale pending duplicates,
  # etc.), so callers auditing classification must be able to skip them.
  test "each transaction reports whether it is excluded from reports" do
    @transaction.entry.update!(excluded: true)

    items = @function.call("page_size" => 100)[:transactions].index_by { |t| t[:id] }

    assert_equal true, items[@transaction.id][:excluded]
    # Sparse: the key is left out when false.
    assert_not items[transactions(:transfer_out).id].key?(:excluded)
  end
  test "reports kind and entry id on every row" do
    result = @function.call("search" => @transaction.entry.name)

    row = result[:transactions].find { |item| item[:id] == @transaction.id }

    assert_equal @transaction.kind, row[:kind]
    assert_equal @transaction.entry.id, row[:entry_id]
  end

  test "flags a pending transaction and stays silent on a settled one" do
    @transaction.update!(extra: { "simplefin" => { "pending" => true } })

    result = @function.call("search" => @transaction.entry.name)
    row = result[:transactions].find { |item| item[:id] == @transaction.id }

    assert_equal true, row[:pending]

    @transaction.update!(extra: {})
    settled = @function.call("search" => @transaction.entry.name)
      .fetch(:transactions).find { |item| item[:id] == @transaction.id }

    assert_not settled.key?(:pending), "an absent key must mean not pending"
  end

  test "names the account on the other side of a transfer" do
    outflow_entry = Entry.create!(
      account: accounts(:depository),
      name: "Transfer out",
      date: Date.current,
      amount: 250,
      currency: "USD",
      entryable: Transaction.new(kind: "funds_movement")
    )
    inflow_entry = Entry.create!(
      account: accounts(:credit_card),
      name: "Transfer in",
      date: Date.current,
      amount: -250,
      currency: "USD",
      entryable: Transaction.new(kind: "cc_payment")
    )
    Transfer.create!(
      inflow_transaction: inflow_entry.entryable,
      outflow_transaction: outflow_entry.entryable
    )

    result = @function.call("search" => "Transfer out")
    row = result[:transactions].find { |item| item[:id] == outflow_entry.entryable.id }

    assert_equal true, row[:is_transfer]
    assert_equal "funds_movement", row[:kind]
    assert_equal accounts(:credit_card).name, row[:transfer_account]
  end

  # The visible leg belongs in the result; the account on the far end does not
  # belong to this user and naming it would disclose it.
  test "hides the counterparty account when the far leg is inaccessible" do
    outflow_entry = Entry.create!(
      account: accounts(:depository),
      name: "Transfer to private account",
      date: Date.current,
      amount: 250,
      currency: "USD",
      entryable: Transaction.new(kind: "funds_movement")
    )
    inflow_entry = Entry.create!(
      account: accounts(:investment),
      name: "Transfer in",
      date: Date.current,
      amount: -250,
      currency: "USD",
      entryable: Transaction.new(kind: "funds_movement")
    )
    Transfer.create!(
      inflow_transaction: inflow_entry.entryable,
      outflow_transaction: outflow_entry.entryable
    )

    result = Assistant::Function::GetTransactions.new(users(:family_member)).call("search" => "Transfer to private account")
    row = result[:transactions].find { |item| item[:id] == outflow_entry.entryable.id }

    assert_not_nil row, "the leg on the shared account is still visible"
    assert_equal true, row[:is_transfer]
    assert_not row.key?(:transfer_account), "an inaccessible counterparty must not be named"
  end

  test "omits transfer_account on a plain transaction" do
    result = @function.call("search" => @transaction.entry.name)
    row = result[:transactions].find { |item| item[:id] == @transaction.id }

    assert_not row.key?(:transfer_account)
  end

  test "cleans a raw bank label and surfaces the rail and operation date" do
    @transaction.entry.update!(name: "CB 02/09 CARREFOUR MARKET", date: Date.new(2026, 9, 5))

    row = @function.call("search" => "CARREFOUR")
      .fetch(:transactions).find { |item| item[:id] == @transaction.id }

    assert_equal "CB 02/09 CARREFOUR MARKET", row[:name]
    assert_equal "CARREFOUR MARKET", row[:clean_name]
    assert_equal "card", row[:rail]
    assert_equal Date.new(2026, 9, 2), row[:operation_date]
  end

  test "omits clean_name, rail and operation_date on a user-written name" do
    @transaction.entry.update!(name: "Groceries")

    row = @function.call("search" => "Groceries")
      .fetch(:transactions).find { |item| item[:id] == @transaction.id }

    assert_not row.key?(:clean_name)
    assert_not row.key?(:rail)
    assert_not row.key?(:operation_date)
  end

  test "omits operation_date when it matches the stored date" do
    @transaction.entry.update!(name: "CB 05/09 FNAC", date: Date.new(2026, 9, 5))

    row = @function.call("search" => "FNAC")
      .fetch(:transactions).find { |item| item[:id] == @transaction.id }

    assert_equal "FNAC", row[:clean_name]
    assert_not row.key?(:operation_date), "no point repeating the date the row already carries"
  end
end
