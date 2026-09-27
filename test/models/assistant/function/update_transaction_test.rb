require "test_helper"

class Assistant::Function::UpdateTransactionTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @transaction = transactions(:one)
    @function = Assistant::Function::UpdateTransaction.new(@user)
  end

  test "updates category notes and tags" do
    category = categories(:subcategory)
    tag = tags(:one)

    result = @function.call(
      "id" => @transaction.id,
      "category_id" => category.id,
      "notes" => "Updated by assistant",
      "tag_ids" => [ tag.id ]
    )

    assert_equal true, result[:success]

    @transaction.reload
    assert_equal category, @transaction.category
    assert_equal "Updated by assistant", @transaction.entry.notes
    assert_equal [ tag.id ], @transaction.tag_ids
  end

  test "category and tags in one call lock both, and nothing locks locked_attributes itself" do
    result = @function.call(
      "id" => @transaction.id,
      "category_id" => categories(:subcategory).id,
      "tag_ids" => [ tags(:one).id ]
    )

    assert_equal true, result[:success]

    @transaction.reload
    assert @transaction.locked?(:category_id), "category_id was not locked"
    assert @transaction.locked?(:tag_ids), "tag_ids was not locked"

    # The same union get_transactions reports as `locked`
    locked = (@transaction.locked_attributes.keys + @transaction.entry.locked_attributes.keys).uniq
    assert_not_includes locked, "locked_attributes"
  end

  test "clears category merchant notes and tags when explicitly requested" do
    @transaction.update!(category: categories(:food_and_drink), merchant: merchants(:amazon))
    @transaction.tags = [ tags(:one) ]

    result = @function.call(
      "id" => @transaction.id,
      "category_id" => nil,
      "merchant_id" => nil,
      "notes" => nil,
      "tag_ids" => []
    )

    assert_equal true, result[:success]

    @transaction.reload
    assert_nil @transaction.category
    assert_nil @transaction.merchant
    assert_nil @transaction.entry.notes
    assert_empty @transaction.tags
    assert @transaction.locked?(:tag_ids)
  end

  test "rejects categories outside the family" do
    other_category = Category.create!(
      family: families(:empty),
      name: "Other",
      color: "#e99537",
      lucide_icon: "tag"
    )

    result = @function.call(
      "id" => @transaction.id,
      "category_id" => other_category.id
    )

    assert_equal false, result[:success]
    assert_equal "invalid_category", result[:error]
  end

  test "does not let read-only collaborators update transactions" do
    transaction = transactions(:transfer_in)
    function = Assistant::Function::UpdateTransaction.new(users(:family_member))

    result = function.call("id" => transaction.id, "notes" => "Should not be saved")

    assert_equal false, result[:success]
    assert_equal "not_authorized", result[:error]
    assert_nil transaction.reload.entry.notes
  end

  test "lets read-write collaborators update annotations but not names" do
    transaction = transactions(:transfer_in)
    transaction.entry.account.account_shares.find_by!(user: users(:family_member)).update!(permission: "read_write")
    function = Assistant::Function::UpdateTransaction.new(users(:family_member))

    annotation_result = function.call("id" => transaction.id, "notes" => "Shared note")
    rename_result = function.call("id" => transaction.id, "name" => "Renamed transaction")

    assert_equal true, annotation_result[:success]
    assert_equal "Shared note", transaction.reload.entry.notes
    assert_equal false, rename_result[:success]
    assert_equal "not_authorized", rename_result[:error]
    assert_equal "Payment received from checking account", transaction.reload.entry.name
  end

  test "any successful update marks the entry user modified so syncs and review stop touching it" do
    assert_not @transaction.entry.user_modified?

    result = @function.call("id" => @transaction.id, "notes" => "Checked")

    assert_equal true, result[:success]
    assert @transaction.reload.entry.user_modified?
  end

  test "sets kind, locks it and reports it" do
    result = @function.call("id" => @transaction.id, "kind" => "one_time")

    assert_equal true, result[:success]
    assert_equal "one_time", result[:transaction][:kind]
    assert_equal false, result[:transaction][:has_transfer_link]

    @transaction.reload
    assert_equal "one_time", @transaction.kind
    assert @transaction.locked?(:kind)
    assert @transaction.entry.user_modified?
  end

  test "locks kind even when it already has the requested value" do
    result = @function.call("id" => @transaction.id, "kind" => "standard")

    assert_equal true, result[:success]
    assert @transaction.reload.locked?(:kind)
  end

  test "refuses to change a ledger-only kind such as debt interest" do
    @transaction.update!(kind: "debt_interest")

    result = @function.call("id" => @transaction.id, "kind" => "standard")

    assert_equal false, result[:success]
    assert_equal "ledger_only", result[:error]
    assert_equal "debt_interest", @transaction.reload.kind
    assert_not @transaction.locked?(:kind)
  end

  test "rejects kinds that belong to transfers" do
    result = @function.call("id" => @transaction.id, "kind" => "cc_payment")

    assert_equal false, result[:success]
    assert_equal "invalid_kind", result[:error]
    assert_equal "standard", @transaction.reload.kind
  end

  test "refuses to change the kind of a transfer leg" do
    transaction = transactions(:transfer_out)
    original_kind = transaction.kind

    result = @function.call("id" => transaction.id, "kind" => "standard")

    assert_equal false, result[:success]
    assert_equal "has_transfer", result[:error]
    assert_equal original_kind, transaction.reload.kind
    assert transaction.transfer.present?
  end

  test "sets and clears the investment activity label, locking it" do
    result = @function.call("id" => @transaction.id, "investment_activity_label" => "Buy")

    assert_equal true, result[:success]
    assert_equal "Buy", result[:transaction][:investment_activity_label]
    assert_equal "Buy", @transaction.reload.investment_activity_label
    assert @transaction.locked?(:investment_activity_label)
    assert @transaction.entry.user_modified?

    result = @function.call("id" => @transaction.id, "investment_activity_label" => nil)

    assert_equal true, result[:success]
    assert_nil @transaction.reload.investment_activity_label
    assert @transaction.locked?(:investment_activity_label)
  end

  test "rejects unknown investment activity labels" do
    result = @function.call("id" => @transaction.id, "investment_activity_label" => "Purchase")

    assert_equal false, result[:success]
    assert_equal "invalid_investment_activity_label", result[:error]
    assert_nil @transaction.reload.investment_activity_label
  end

  test "reject_transfer unlinks both legs and remembers the rejection" do
    outflow = transactions(:transfer_out)
    inflow = transactions(:transfer_in)

    result = @function.call("id" => outflow.id, "reject_transfer" => true)

    assert_equal true, result[:success]
    assert_equal false, result[:transaction][:has_transfer_link]
    assert_nil outflow.reload.transfer
    assert_nil inflow.reload.transfer
    assert_equal "standard", outflow.kind
    assert_equal "standard", inflow.kind
    assert RejectedTransfer.exists?(inflow_transaction_id: inflow.id, outflow_transaction_id: outflow.id)
    assert outflow.entry.user_modified?
  end

  test "reject_transfer refuses when the transfer has fee transactions, keeping the fees" do
    outflow = transactions(:transfer_out)
    transfer = outflow.transfer
    fee_entry = accounts(:depository).entries.create!(name: "Wire fee", date: Date.current, amount: 5, currency: "USD", entryable: Transaction.new(kind: "standard"))
    transfer.fee_transactions << fee_entry.entryable

    result = @function.call("id" => outflow.id, "reject_transfer" => true)

    assert_equal false, result[:success]
    assert_equal "transfer_has_fees", result[:error]
    assert Entry.exists?(fee_entry.id)
    assert outflow.reload.transfer.present?
    assert_not RejectedTransfer.exists?(inflow_transaction_id: transfer.inflow_transaction_id, outflow_transaction_id: outflow.id)
  end

  test "reject_transfer queues a balance sync for both legs' accounts" do
    outflow = transactions(:transfer_out)
    inflow = transactions(:transfer_in)
    accounts = [ outflow.entry.account, inflow.entry.account ]
    assert_not_equal accounts.first, accounts.last

    counts = accounts.to_h { |account| [ -> { Sync.where(syncable: account).count }, 1 ] }

    assert_difference counts do
      result = @function.call("id" => outflow.id, "reject_transfer" => true)
      assert_equal true, result[:success]
    end
  end

  test "refuses kind or activity label on a split parent" do
    entry = @transaction.entry
    entry.split!([
      { name: "Part A", amount: entry.amount / 2, category_id: nil },
      { name: "Part B", amount: entry.amount - (entry.amount / 2), category_id: nil }
    ])

    [ { "kind" => "one_time" }, { "investment_activity_label" => "Buy" } ].each do |params|
      result = @function.call(params.merge("id" => @transaction.id))

      assert_equal false, result[:success], params.inspect
      assert_equal "split_parent", result[:error]
    end

    @transaction.reload
    assert_equal "standard", @transaction.kind
    assert_nil @transaction.investment_activity_label
    assert_not @transaction.locked?(:kind)
  end

  test "reject_transfer is not authorized when the other leg's account is not fully writable" do
    # Fixtures: family_member has full_control of checking (the outflow) but
    # only read_only access to the credit card (the inflow)
    outflow = transactions(:transfer_out)
    function = Assistant::Function::UpdateTransaction.new(users(:family_member))

    result = function.call("id" => outflow.id, "reject_transfer" => true)

    assert_equal false, result[:success]
    assert_equal "not_authorized", result[:error]
    assert_match "both sides", result[:message]
    assert outflow.reload.transfer.present?
    assert_not outflow.entry.user_modified?
  end

  test "reject_transfer and kind combine in one call" do
    inflow = transactions(:transfer_in)

    result = @function.call("id" => inflow.id, "reject_transfer" => true, "kind" => "one_time")

    assert_equal true, result[:success]
    assert_equal "one_time", result[:transaction][:kind]
    assert_equal "one_time", inflow.reload.kind
    assert inflow.locked?(:kind)
    assert_nil inflow.transfer
  end

  test "reject_transfer on a transaction that is not a transfer leg is an error" do
    result = @function.call("id" => @transaction.id, "reject_transfer" => true)

    assert_equal false, result[:success]
    assert_equal "no_transfer", result[:error]
    assert_not @transaction.reload.entry.user_modified?
  end

  test "reject_transfer false alone is not a change" do
    result = @function.call("id" => @transaction.id, "reject_transfer" => false)

    assert_equal false, result[:success]
    assert_equal "no_changes", result[:error]
  end

  test "read-write collaborators cannot change kind, label or transfers" do
    transaction = transactions(:transfer_in)
    transaction.entry.account.account_shares.find_by!(user: users(:family_member)).update!(permission: "read_write")
    function = Assistant::Function::UpdateTransaction.new(users(:family_member))

    [
      { "kind" => "one_time", "reject_transfer" => true },
      { "investment_activity_label" => "Buy" },
      { "reject_transfer" => true }
    ].each do |params|
      result = function.call(params.merge("id" => transaction.id))

      assert_equal false, result[:success]
      assert_equal "not_authorized", result[:error]
    end

    assert transaction.reload.transfer.present?
    assert_nil transaction.investment_activity_label
  end
end
