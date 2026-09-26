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
end
