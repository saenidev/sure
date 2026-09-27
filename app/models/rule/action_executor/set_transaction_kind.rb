class Rule::ActionExecutor::SetTransactionKind < Rule::ActionExecutor
  # Kinds that describe a single transaction on its own. Transfer kinds
  # (cc_payment, loan_payment, investment_contribution) come from a Transfer
  # with two legs, so a rule cannot set them.
  KINDS = %w[standard funds_movement one_time].freeze

  def label
    I18n.t("rules.action_executors.set_transaction_kind.label")
  end

  def type
    "select"
  end

  def options
    KINDS.map { |kind| [ I18n.t("rules.action_executors.set_transaction_kind.kinds.#{kind}"), kind ] }
  end

  # A kind the user set by hand always wins, even on an explicit "apply rule"
  # (ignore_attribute_locks: true), because rules run over the whole history
  # every night and would otherwise undo the user's fixes.
  def execute(transaction_scope, value: nil, ignore_attribute_locks: false, rule_run: nil)
    return 0 unless KINDS.include?(value)

    scope = transaction_scope
      .enrichable(:kind)
      .where.not(id: Transfer.select(:inflow_transaction_id))
      .where.not(id: Transfer.select(:outflow_transaction_id))

    count_modified_resources(scope) do |txn|
      txn.enrich_attribute(:kind, value, source: "rule")
    end
  end
end
