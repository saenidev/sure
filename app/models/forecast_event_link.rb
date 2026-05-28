class ForecastEventLink < ApplicationRecord
  LINK_TYPES = %w[actual pending duplicate replacement].freeze
  STATUSES = %w[candidate accepted rejected superseded].freeze

  belongs_to :family
  belongs_to :forecast_event, optional: true
  belongs_to :entry, optional: true

  before_validation :default_occurrence_on_from_event
  before_validation :snapshot_event, if: :event_snapshot_needs_refresh?
  before_validation :snapshot_entry, if: :entry_snapshot_needs_refresh?

  validates :link_type, :status, presence: true
  validates :link_type, inclusion: { in: LINK_TYPES }
  validates :status, inclusion: { in: STATUSES }
  validates :entry_id, uniqueness: { scope: :forecast_event_id }, allow_nil: true
  validates :entry_id, uniqueness: { conditions: -> { where(status: "accepted") }, message: "already has an accepted forecast event link" }, allow_nil: true, if: -> { status == "accepted" }
  validates :occurrence_on, uniqueness: { scope: :forecast_event_id, conditions: -> { where(status: "accepted") } }, allow_nil: true, if: -> { status == "accepted" }
  validate :records_belong_to_family
  validate :accepted_links_require_occurrence
  validate :accepted_links_require_entry
  validate :accepted_links_require_transaction_entry
  validate :accepted_link_references_are_immutable, on: :update

  private
    def records_belong_to_family
      if forecast_event.present? && forecast_event.family_id != family_id
        errors.add(:forecast_event, "must belong to the forecast family")
      end

      if entry.present? && entry.account.family_id != family_id
        errors.add(:entry, "must belong to the forecast family")
      end
    end

    def accepted_link_references_are_immutable
      return unless status_in_database == "accepted"
      return unless will_save_change_to_forecast_event_id? || will_save_change_to_entry_id? || will_save_change_to_occurrence_on? || will_save_change_to_event_snapshot? || will_save_change_to_entry_snapshot?

      errors.add(:base, "accepted forecast event links cannot change linked records or snapshots")
    end

    def accepted_links_require_occurrence
      return unless status == "accepted"
      return if occurrence_on.present?

      errors.add(:occurrence_on, "must be present for accepted links")
    end

    def accepted_links_require_entry
      return unless status == "accepted"
      return if entry.present?
      return if persisted? && entry_id.blank? && entry_snapshot.present? && !will_save_change_to_status?

      errors.add(:entry, "must be present for accepted links")
    end

    def accepted_links_require_transaction_entry
      return unless status == "accepted" && entry.present?
      return if entry.transaction? && !entry.excluded?

      errors.add(:entry, "must be a transaction entry for accepted links")
    end

    def event_snapshot_needs_refresh?
      forecast_event.present? && (event_snapshot.blank? || will_save_change_to_forecast_event_id?)
    end

    def default_occurrence_on_from_event
      self.occurrence_on ||= forecast_event&.starts_on
    end

    def snapshot_event
      self.event_snapshot = {
        "id" => forecast_event.id,
        "name" => forecast_event.name,
        "effect_type" => forecast_event.effect_type,
        "behavior" => forecast_event.behavior,
        "amount" => forecast_event.amount&.to_s,
        "currency" => forecast_event.currency,
        "occurrence_on" => occurrence_on&.iso8601,
        "starts_on" => forecast_event.starts_on&.iso8601,
        "ends_on" => forecast_event.ends_on&.iso8601,
        "forecast_scenario_id" => forecast_event.forecast_scenario_id,
        "account_id" => forecast_event.account_id,
        "destination_account_id" => forecast_event.destination_account_id,
        "category" => category_snapshot(forecast_event.category)
      }
    end

    def entry_snapshot_needs_refresh?
      entry.present? && (entry_snapshot.blank? || will_save_change_to_entry_id?)
    end

    def snapshot_entry
      transfer = entry.transaction? ? (entry.transaction.transfer_as_outflow || entry.transaction.transfer_as_inflow) : nil
      outflow_entry = transfer&.outflow_transaction&.entry
      inflow_entry = transfer&.inflow_transaction&.entry

      self.entry_snapshot = {
        "id" => entry.id,
        "date" => entry.date&.iso8601,
        "name" => entry.name,
        "amount" => entry.amount&.to_s,
        "currency" => entry.currency,
        "account_id" => entry.account_id,
        "entryable_type" => entry.entryable_type,
        "entryable_id" => entry.entryable_id,
        "transaction_kind" => entry.transaction? ? entry.transaction.kind : nil,
        "transfer_role" => transfer_role_for(entry, transfer),
        "transfer_source_account_id" => transfer&.from_account&.id,
        "transfer_destination_account_id" => transfer&.to_account&.id,
        "transfer_source_amount" => outflow_entry&.amount&.abs&.to_s,
        "transfer_source_currency" => outflow_entry&.currency,
        "transfer_source_date" => outflow_entry&.date&.iso8601,
        "transfer_destination_amount" => inflow_entry&.amount&.abs&.to_s,
        "transfer_destination_currency" => inflow_entry&.currency,
        "transfer_destination_date" => inflow_entry&.date&.iso8601,
        "category" => category_snapshot(entry.transaction? ? entry.transaction.category : nil)
      }
    end

    def transfer_role_for(entry, transfer)
      return nil if transfer.blank?
      return "outflow" if transfer.outflow_transaction_id == entry.entryable_id
      "inflow" if transfer.inflow_transaction_id == entry.entryable_id
    end

    def category_snapshot(category)
      return nil if category.blank?

      {
        "id" => category.id,
        "name" => category.name,
        "parent_id" => category.parent_id,
        "parent_name" => category.parent&.name
      }
    end
end
