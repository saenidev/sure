class Assistant::Function::UpdateTransaction < Assistant::Function
  class << self
    def name
      "update_transaction"
    end

    def description
      <<~INSTRUCTIONS
        Updates an existing transaction.

        Use get_transactions first to find the transaction id, and get_categories,
        get_tags, or the current transaction merchant before referencing related ids.

        This tool can update the transaction name, notes, category, merchant,
        tags, kind and investment activity label, and can reject a wrong
        transfer match. It will not edit split child transactions directly.

        Use kind to fix how a transaction counts in reports: standard (income or
        spending), funds_movement (money moving between the user's own accounts,
        not counted) or one_time (a windfall or one-off kept out of budgets).
        Transfer legs keep the kind their transfer gives them; pass
        reject_transfer: true (optionally together with kind) to unlink a wrong
        match first. Rejecting needs full access to both accounts, re-syncs
        both, and is refused (transfer_has_fees) when the transfer carries fee
        transactions, since rejecting would delete them. Every successful update marks the transaction as edited by
        the user, so syncs and rules will not overwrite it.
      INSTRUCTIONS
    end
  end

  EDITABLE_KINDS = %w[standard funds_movement one_time].freeze

  def strict_mode?
    false
  end

  def params_schema
    build_schema(
      required: [ "id" ],
      properties: {
        id: {
          type: "string",
          description: "Transaction ID from get_transactions"
        },
        name: {
          type: "string",
          description: "New transaction name. Omit to leave unchanged."
        },
        notes: {
          type: [ "string", "null" ],
          description: "New transaction notes. Use null to clear notes. Omit to leave unchanged."
        },
        category_id: {
          type: [ "string", "null" ],
          description: "Category ID from get_categories. Use null to clear category. Omit to leave unchanged."
        },
        merchant_id: {
          type: [ "string", "null" ],
          description: "Merchant ID currently available to the family. Use null to clear merchant. Omit to leave unchanged."
        },
        tag_ids: {
          type: "array",
          items: { type: "string" },
          description: "Full list of tag IDs to set. Use an empty array to clear all tags. Omit to leave unchanged."
        },
        kind: {
          type: "string",
          enum: EDITABLE_KINDS,
          description: "How the transaction counts in reports: standard, funds_movement (own money moving between accounts) or one_time. Not allowed on a transfer leg unless reject_transfer is true. Omit to leave unchanged."
        },
        investment_activity_label: {
          type: [ "string", "null" ],
          enum: Transaction::ACTIVITY_LABELS + [ nil ],
          description: "Investment activity label (e.g. Buy, Sell, Dividend). Use null to clear. Omit to leave unchanged."
        },
        reject_transfer: {
          type: "boolean",
          description: "true to unlink this transaction from its transfer (both legs go back to standard and the pair is never auto-matched again). Refused when the transfer has fee transactions. Omit otherwise."
        }
      }
    )
  end

  def call(params = {})
    transaction = find_transaction(params["id"])
    return error("not_found", "Transaction with id '#{params["id"]}' not found.") unless transaction

    entry = transaction.entry
    return error("split_child", "Split child transactions cannot be edited directly. Use the split editor.") if entry.split_child?
    return error("not_authorized", "You do not have permission to update this transaction.") unless permitted_to_update?(entry.account, params)

    reject_transfer = params["reject_transfer"] == true
    transfer = transaction.transfer
    if reject_transfer
      return error("no_transfer", "This transaction is not part of a transfer.") unless transfer
      return error("not_authorized", "You do not have permission to update both sides of this transfer.") unless permitted_to_reject?(transfer)
      # Rejecting destroys the transfer's fee transactions along with it
      return error("transfer_has_fees", "This transfer has fee transactions that rejecting it would delete. Edit it in the app instead.") if transfer.has_fees?
    elsif params.key?("kind") && transfer
      return error("has_transfer", "This transaction is part of a transfer. Pass reject_transfer: true to unlink it before changing its kind.")
    end

    if params.key?("kind") && Transaction::LEDGER_ONLY_KINDS.include?(transaction.kind)
      return error("ledger_only", "This transaction is a #{transaction.kind} ledger entry; its kind cannot be changed.")
    end

    entry_attrs = entry_attributes(params, entry)
    return entry_attrs if error_response?(entry_attrs)

    tag_ids = nil
    if params.key?("tag_ids")
      tag_ids = Array(params["tag_ids"]).map(&:to_s).reject(&:blank?)
      return error("invalid_tags", "One or more tag_ids do not belong to the user's family.") unless valid_tag_ids?(tag_ids)
    end

    return error("no_changes", "Provide at least one field to update.") if no_changes?(entry_attrs, params)

    Entry.transaction do
      if reject_transfer
        # Both legs' balances change, not only this one's; queue before the
        # destroy while the transfer still knows its legs
        transfer.sync_account_later
        transfer.reject!
        # reject! resets both legs through its own copies of the transactions
        transaction.reload
        entry = transaction.entry
      end

      entry.update!(entry_attrs)
      # Lock straight after the update, while saved_changes still describes it;
      # any later save (tags, other locks) would reset it.
      entry.lock_saved_attributes!
      # Work on the instance the update and locks went through, so later
      # lock_attr! calls merge into its current locked_attributes, not a stale copy
      transaction = entry.entryable

      if params.key?("tag_ids")
        transaction.tag_ids = tag_ids
        transaction.save!
        transaction.lock_attr!(:tag_ids)
      end

      # Lock even when the value was already right, so rules and syncs keep it
      transaction.lock_attr!(:kind) if params.key?("kind")
      transaction.lock_attr!(:investment_activity_label) if params.key?("investment_activity_label")
      entry.mark_user_modified!
      entry.sync_account_later
    end

    {
      success: true,
      transaction: serialize(transaction.reload),
      message: "Transaction '#{transaction.entry.name}' updated."
    }
  rescue ActiveRecord::RecordInvalid => e
    error("validation_failed", e.record.errors.full_messages.join("; "))
  end

  private
    def find_transaction(id)
      return nil unless valid_uuid?(id)

      family.transactions
        .joins(:entry)
        .where(entries: { account_id: user.accessible_accounts.visible.select(:id) })
        .find_by(id: id)
    end

    def permitted_to_update?(account, params)
      permission = account.permission_for(user)
      return true if permission.in?([ :owner, :full_control ])

      permission == :read_write && (params.keys & %w[name kind investment_activity_label reject_transfer]).empty?
    end

    def permitted_to_reject?(transfer)
      [ transfer.inflow_transaction, transfer.outflow_transaction ].all? do |leg|
        leg.entry.account.permission_for(user).in?([ :owner, :full_control ])
      end
    end

    def entry_attributes(params, entry)
      entryable_attrs = { id: entry.entryable_id }

      if params.key?("category_id")
        category_id = optional_uuid(params["category_id"])
        return category_id if error_response?(category_id)
        return error("invalid_category", "category_id does not belong to the user's family.") if category_id && !family.categories.exists?(id: category_id)

        entryable_attrs[:category_id] = category_id
      end

      if params.key?("merchant_id")
        merchant_id = optional_uuid(params["merchant_id"])
        return merchant_id if error_response?(merchant_id)
        return error("invalid_merchant", "merchant_id is not available to the user's family.") if merchant_id && !available_merchants.exists?(id: merchant_id)

        entryable_attrs[:merchant_id] = merchant_id
      end

      if params.key?("kind")
        return error("invalid_kind", "kind must be one of: #{EDITABLE_KINDS.join(', ')}.") unless EDITABLE_KINDS.include?(params["kind"])

        entryable_attrs[:kind] = params["kind"]
      end

      if params.key?("investment_activity_label")
        label = params["investment_activity_label"]
        unless label.nil? || Transaction::ACTIVITY_LABELS.include?(label)
          return error("invalid_investment_activity_label", "investment_activity_label must be null or one of: #{Transaction::ACTIVITY_LABELS.join(', ')}.")
        end

        entryable_attrs[:investment_activity_label] = label
      end

      attrs = {}
      attrs[:name] = params["name"].to_s.strip if params.key?("name")
      attrs[:notes] = params["notes"] if params.key?("notes")
      attrs[:entryable_attributes] = entryable_attrs if entryable_attrs.keys.size > 1
      attrs
    end

    def optional_uuid(value)
      return nil if value.nil? || value == ""
      return value.to_s if valid_uuid?(value)

      error("invalid_uuid", "Expected a valid UUID.")
    end

    def valid_tag_ids?(tag_ids)
      family.tags.where(id: tag_ids).count == tag_ids.uniq.size
    end

    def available_merchants
      family.available_merchants_for(user)
    end

    def no_changes?(entry_attrs, params)
      entry_attrs.empty? && !params.key?("tag_ids") && params["reject_transfer"] != true
    end

    def serialize(transaction)
      entry = transaction.entry
      {
        id: transaction.id,
        name: entry.name,
        date: entry.date,
        notes: entry.notes,
        category: transaction.category && {
          id: transaction.category.id,
          name: transaction.category.name
        },
        merchant: transaction.merchant && {
          id: transaction.merchant.id,
          name: transaction.merchant.name
        },
        tags: transaction.tags.map { |tag| { id: tag.id, name: tag.name } },
        kind: transaction.kind,
        investment_activity_label: transaction.investment_activity_label,
        has_transfer_link: transaction.transfer.present?
      }
    end

    def error_response?(value)
      value.is_a?(Hash) && value[:success] == false
    end

    def error(key, message)
      { success: false, error: key, message: message }
    end
end
