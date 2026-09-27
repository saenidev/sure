require "test_helper"

class Rule::ActionExecutor::SetTransactionKindTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:dylan_family)
    @rule = rules(:one)
    @account = @family.accounts.create!(name: "Kind rule test", balance: 1000, currency: "USD", accountable: Depository.new)

    @txn1 = create_transaction(date: Date.current, account: @account, amount: 1000, name: "Wise send").transaction
    @txn2 = create_transaction(date: Date.current, account: @account, amount: 2000, name: "Wise send").transaction

    @scope = @account.transactions
  end

  test "is a select offering only kinds that do not need a counterpart" do
    executor = Rule::ActionExecutor::SetTransactionKind.new(@rule)

    assert_equal "select", executor.type
    assert_equal %w[standard funds_movement one_time], executor.options.map(&:last)
    assert executor.label.present?
    assert_includes @rule.registry.action_executors.map(&:key), "set_transaction_kind"
  end

  test "sets the kind and records the rule as its source" do
    modified = apply_kind("funds_movement")

    assert_equal 2, modified
    [ @txn1, @txn2 ].each do |txn|
      assert_equal "funds_movement", txn.reload.kind
      assert DataEnrichment.exists?(enrichable: txn, attribute_name: "kind", source: "rule")
    end
  end

  test "re-running the rule changes nothing" do
    apply_kind("funds_movement")

    assert_equal 0, apply_kind("funds_movement")
    assert_equal "funds_movement", @txn1.reload.kind
  end

  test "never overrides a kind the user locked, even when the rule ignores locks" do
    @txn1.update!(kind: "one_time")
    @txn1.lock_attr!(:kind)

    apply_kind("funds_movement")
    apply_kind("funds_movement", ignore_attribute_locks: true)

    assert_equal "one_time", @txn1.reload.kind
    assert_equal "funds_movement", @txn2.reload.kind
  end

  test "other locks are still overridden when the rule ignores locks" do
    @txn1.lock_attr!(:category_id)

    apply_kind("one_time", ignore_attribute_locks: true)

    assert_equal "one_time", @txn1.reload.kind
  end

  test "skips transactions that are legs of a transfer" do
    outflow = transactions(:transfer_out)
    inflow = transactions(:transfer_in)
    original_kinds = [ outflow.kind, inflow.kind ]

    modified = apply_kind("one_time", scope: Transaction.where(id: [ outflow.id, inflow.id, @txn1.id ]), ignore_attribute_locks: true)

    assert_equal 1, modified
    assert_equal "one_time", @txn1.reload.kind
    assert_equal original_kinds, [ outflow.reload.kind, inflow.reload.kind ]
    assert outflow.transfer.present?
  end

  test "never overrides a ledger-only kind such as debt interest" do
    @txn1.update!(kind: "debt_interest")
    @txn2.update!(kind: "one_time")

    modified = apply_kind("standard", ignore_attribute_locks: true)

    assert_equal 1, modified
    assert_equal "debt_interest", @txn1.reload.kind
    assert_equal "standard", @txn2.reload.kind
  end

  test "ignores kinds outside the allowed list" do
    assert_equal 0, apply_kind("cc_payment")
    assert_equal 0, apply_kind("bogus")
    assert_equal "standard", @txn1.reload.kind
  end

  private
    def apply_kind(kind, scope: @scope, ignore_attribute_locks: false)
      Rule::Action.new(rule: @rule, action_type: "set_transaction_kind", value: kind)
        .apply(scope, ignore_attribute_locks: ignore_attribute_locks)
    end
end
