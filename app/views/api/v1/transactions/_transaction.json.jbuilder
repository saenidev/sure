# frozen_string_literal: true

json.id transaction.id
json.date transaction.entry.date
json.amount transaction.entry.amount_money.format

# Agent/automation-friendly numeric fields (avoid localized parsing and clarify sign)
# `amount` in v1 is a localized string and may follow an accounting sign convention.
# Expose minor units (cents) as integers to make the API agent-friendly.
# Uses currency.minor_unit_conversion (e.g. 100 for USD/EUR, 1 for JPY, 1000 for KWD).
amount_money = transaction.entry.amount_money
conversion_factor = amount_money.currency.minor_unit_conversion
amount_cents = (amount_money.amount * conversion_factor).round(0).to_i.abs
json.amount_cents amount_cents
json.signed_amount_cents(transaction.entry.classification == "income" ? amount_cents : -amount_cents)

json.currency transaction.entry.currency
json.name transaction.entry.name
json.notes transaction.entry.notes
json.external_id transaction.entry.external_id
json.source transaction.entry.source
json.user_modified transaction.entry.user_modified
json.classification transaction.entry.classification
json.pending transaction.pending?
json.excluded transaction.entry.excluded

# Shortcut purchase hints (source "shortcut") and the posted transactions that
# settled them. status is set on hints only: pending, settled or excluded.
shortcut = ShortcutPending.data(transaction)
if shortcut.present?
  json.shortcut do
    json.status(
      if !transaction.entry.shortcut? then nil
      elsif shortcut["settled_by_entry_id"].present? then "settled"
      elsif transaction.entry.excluded? then "excluded"
      else "pending"
      end
    )
    json.origins shortcut["origins"] || []
    json.occurred_at shortcut["occurred_at"]
    json.original_amount shortcut["original_amount"]
    json.original_currency shortcut["original_currency"]
    json.conversion shortcut["conversion"]
    json.settled_by_transaction_id shortcut["settled_by_transaction_id"]
    json.settled_by_entry_id shortcut["settled_by_entry_id"]
    json.settled_at shortcut["settled_at"]
    json.settlement_match shortcut["settlement_match"]
    json.matched_pending_transaction_id shortcut["matched_pending_transaction_id"]
    json.matched_pending_entry_id shortcut["matched_pending_entry_id"]
  end
else
  json.shortcut nil
end

# Account information
json.account do
  json.id transaction.entry.account.id
  json.name transaction.entry.account.name
  json.account_type transaction.entry.account.accountable_type.underscore
end

# Category information
if transaction.category.present?
  json.category do
    json.id transaction.category.id
    json.name transaction.category.name
    json.color transaction.category.color
    json.icon transaction.category.lucide_icon
  end
else
  json.category nil
end

# Merchant information
if transaction.merchant.present?
  json.merchant do
    json.id transaction.merchant.id
    json.name transaction.merchant.name
  end
else
  json.merchant nil
end

# Tags
json.tags transaction.tags do |tag|
  json.id tag.id
  json.name tag.name
  json.color tag.color
end

# Transfer information (if this transaction is part of a transfer)
transfer = transaction.transfer
if transfer.present?
  json.transfer do
    json.id transfer.id

    # Other transaction in the transfer
    if transfer.inflow_transaction_id == transaction.id
      inflow_transaction = transaction
      other_transaction = transfer.outflow_transaction
    else
      inflow_transaction = transfer.inflow_transaction
      # When rendering the outflow, the inflow is the counterparty transaction.
      other_transaction = inflow_transaction
    end

    json.amount inflow_transaction.entry.amount_money.abs.format
    json.currency inflow_transaction.entry.currency

    if other_transaction.present?
      json.other_account do
        json.id other_transaction.entry.account.id
        json.name other_transaction.entry.account.name
        json.account_type other_transaction.entry.account.accountable_type.underscore
      end
    end
  end
else
  json.transfer nil
end

# Additional metadata
json.created_at transaction.created_at.iso8601
json.updated_at transaction.updated_at.iso8601
