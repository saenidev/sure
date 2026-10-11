# Records one purchase hint from an iPhone Shortcut as a pending transaction.
#
# - A retried request (same client_id) returns the existing entry.
# - A hint from the other origin for the same purchase (same amount, within
#   SAME_PURCHASE_WINDOW) folds into the existing entry instead of adding one:
#   the Apple Pay merchant name and the bank alert's amount win.
# - Otherwise a new pending entry is created.
#
# Amounts in a foreign currency are converted to the account currency at the
# purchase date. Without a rate the entry keeps the original currency and is
# flagged "unconverted"; it still counts as pending and can settle later.
class ShortcutPending::Recorder
  include ActiveModel::Model

  Result = Data.define(:entry, :outcome) # outcome: :created, :merged or :existing

  ISO8601_WITH_OFFSET = /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(:\d{2}(\.\d+)?)?(Z|[+-]\d{2}:?\d{2})\z/

  attr_accessor :account, :client_id, :origin, :occurred_at, :amount, :currency,
                :original_amount, :original_currency, :name, :date, :notes,
                :category_id, :merchant_id, :tag_ids

  validates :client_id, presence: true, length: { maximum: 255 }
  validates :origin, inclusion: { in: ShortcutPending::ORIGINS, message: "must be one of: #{ShortcutPending::ORIGINS.join(', ')}" }
  validates :name, presence: true
  validates :amount, numericality: true
  validates :original_amount, numericality: true, allow_blank: true
  validate :occurred_at_has_offset
  validate :date_is_valid
  validate :currencies_are_known
  validate :original_pair_is_complete

  # @return [Result]
  # @raise [ActiveModel::ValidationError] when the request is invalid
  def record!
    raise ActiveModel::ValidationError, self unless valid?

    result = account.with_lock do
      if (existing = find_by_client_id)
        Result.new(entry: existing, outcome: :existing)
      elsif (twin = find_same_purchase)
        merge_into!(twin)
        Result.new(entry: twin, outcome: :merged)
      else
        Result.new(entry: create_entry!, outcome: :created)
      end
    end

    # The bank's posted version may already be here (SimpleFIN was faster, or
    # the phone was offline), so try to settle right away.
    ShortcutPending::Settler.new(account).settle_open! unless result.outcome == :existing

    result.entry.reload
    result
  end

  private

    def find_by_client_id
      account.entries
        .joins("INNER JOIN transactions ON transactions.id = entries.entryable_id AND entries.entryable_type = 'Transaction'")
        .where(source: ShortcutPending::SOURCE)
        .where("entries.external_id = :id OR transactions.extra -> 'shortcut' -> 'client_ids' @> :ids::jsonb", id: client_id.to_s, ids: [ client_id.to_s ].to_json)
        .first
    end

    def find_same_purchase
      candidates = account.entries
        .where(source: ShortcutPending::SOURCE, entryable_type: "Transaction")
        .where(date: (occurred_time.to_date - 1.day)..(occurred_time.to_date + 1.day))
        .includes(:entryable)

      twins = candidates.select { |entry| same_purchase?(entry) }
      twins.min_by { |entry| (occurred_time_of(entry) - occurred_time).abs }
    end

    def same_purchase?(entry)
      data = ShortcutPending.data(entry.entryable)
      return false if Array(data["origins"]).include?(origin)

      other_time = occurred_time_of(entry)
      return false unless other_time && (other_time - occurred_time).abs <= ShortcutPending::SAME_PURCHASE_WINDOW

      same_amount?(entry, data)
    end

    def same_amount?(entry, data)
      if entry.currency == resolved[:currency]
        estimated = resolved[:conversion].in?(%w[converted unconverted]) || data["conversion"].in?(%w[converted unconverted])
        tolerance = estimated ? ShortcutPending::FX_TOLERANCE : 0
        amounts_close?(entry.amount, resolved[:amount], tolerance)
      elsif data["original_currency"].present? && data["original_currency"] == resolved[:original_currency]
        amounts_close?(data["original_amount"].to_d, resolved[:original_amount], 0)
      else
        false
      end
    end

    def amounts_close?(a, b, tolerance)
      return false unless a.positive? == b.positive?

      (a.abs - b.abs).abs <= b.abs * tolerance
    end

    def create_entry!
      account.entries.create!(
        name: name,
        date: entry_date,
        amount: resolved[:amount],
        currency: resolved[:currency],
        notes: notes,
        source: ShortcutPending::SOURCE,
        external_id: client_id.to_s,
        entryable: Transaction.new(
          category_id: category_id,
          merchant_id: merchant_id,
          tag_ids: Array(tag_ids),
          extra: { ShortcutPending::SOURCE => initial_data }
        )
      )
    end

    def initial_data
      {
        "pending" => true,
        "origins" => [ origin ],
        "client_ids" => [ client_id.to_s ],
        "occurred_at" => occurred_time.iso8601,
        "original_amount" => resolved[:original_amount]&.to_s,
        "original_currency" => resolved[:original_currency],
        "conversion" => resolved[:conversion],
        "fx_rate" => resolved[:fx_rate]&.to_s,
        "reports" => [ report ]
      }.compact
    end

    # Folds this hint into the entry recorded by the other origin.
    def merge_into!(entry)
      transaction = entry.entryable
      data = ShortcutPending.data(transaction).deep_dup

      data["origins"] = (Array(data["origins"]) + [ origin ]).uniq
      data["client_ids"] = (Array(data["client_ids"]) + [ client_id.to_s ]).uniq
      data["reports"] = Array(data["reports"]) + [ report ]

      earliest = [ occurred_time_of(entry), occurred_time ].compact.min
      data["occurred_at"] = earliest.iso8601

      if data["original_currency"].blank? && resolved[:original_currency].present?
        data["original_amount"] = resolved[:original_amount].to_s
        data["original_currency"] = resolved[:original_currency]
      end

      attrs = {}
      unless entry.user_modified?
        # Apple Pay knows the merchant's display name; a bank alert carries a
        # descriptor. The bank alert knows the amount the bank will charge.
        attrs[:name] = name if origin == "apple_pay"

        if origin == "bank_alert" && resolved[:currency] == account.currency
          attrs[:amount] = resolved[:amount]
          attrs[:currency] = resolved[:currency]
          data["conversion"] = "provided" if data["original_currency"].present?
          data.delete("fx_rate") if data["conversion"] == "provided"
        end

        attrs[:date] = earliest.to_date if date.blank? && earliest.to_date != entry.date
      end

      entry.update!(attrs) if attrs.any?
      transaction.update!(extra: (transaction.extra || {}).merge(ShortcutPending::SOURCE => data))
    end

    def report
      {
        "origin" => origin,
        "client_id" => client_id.to_s,
        "occurred_at" => occurred_time.iso8601,
        "name" => name,
        "amount" => amount.to_s,
        "currency" => input_currency,
        "original_amount" => original_amount.presence&.to_s,
        "original_currency" => original_currency.presence&.upcase,
        "received_at" => Time.current.iso8601
      }.compact
    end

    # The amount to store, in the account currency when possible.
    def resolved
      @resolved ||= begin
        signed_amount = amount.to_d

        if input_currency == account.currency
          foreign = original_currency.present? && original_currency.upcase != account.currency
          {
            amount: signed_amount,
            currency: account.currency,
            original_amount: foreign ? signed_original(original_amount.to_d, signed_amount) : nil,
            original_currency: foreign ? original_currency.upcase : nil,
            conversion: foreign ? "provided" : nil
          }
        else
          convert_foreign(signed_amount)
        end
      end
    end

    def convert_foreign(signed_amount)
      converted = Money.new(signed_amount, input_currency).exchange_to(account.currency, date: entry_date)
      precision = Money::Currency.new(account.currency).default_precision
      {
        amount: converted.amount.round(precision),
        currency: account.currency,
        original_amount: signed_amount,
        original_currency: input_currency,
        conversion: "converted",
        fx_rate: (converted.amount / signed_amount).round(10)
      }
    rescue Money::ConversionError
      {
        amount: signed_amount,
        currency: input_currency,
        original_amount: signed_amount,
        original_currency: input_currency,
        conversion: "unconverted"
      }
    end

    def signed_original(value, signed_amount)
      signed_amount.negative? ? -value.abs : value.abs
    end

    def input_currency
      (currency.presence || account.currency).to_s.upcase
    end

    def entry_date
      date.present? ? Date.iso8601(date.to_s) : occurred_time.to_date
    end

    def occurred_time
      @occurred_time ||= Time.iso8601(occurred_at.to_s)
    end

    def occurred_time_of(entry)
      value = ShortcutPending.data(entry.entryable)["occurred_at"]
      value.present? ? Time.iso8601(value) : nil
    rescue ArgumentError
      nil
    end

    def occurred_at_has_offset
      if occurred_at.blank? || !occurred_at.to_s.match?(ISO8601_WITH_OFFSET)
        errors.add(:occurred_at, "must be an ISO 8601 timestamp with a UTC offset, e.g. 2026-10-11T14:03:00+09:00")
        return
      end

      occurred_time
    rescue ArgumentError
      errors.add(:occurred_at, "is not a valid timestamp")
    end

    def date_is_valid
      return if date.blank?

      Date.iso8601(date.to_s)
    rescue ArgumentError
      errors.add(:date, "must be an ISO 8601 date (YYYY-MM-DD)")
    end

    def currencies_are_known
      [ [ :currency, currency ], [ :original_currency, original_currency ] ].each do |attribute, value|
        next if value.blank?

        Money::Currency.new(value)
      rescue Money::Currency::UnknownCurrencyError
        errors.add(attribute, "is not a known currency code")
      end
    end

    def original_pair_is_complete
      return if original_amount.blank? && original_currency.blank?

      if original_amount.blank? || original_currency.blank?
        errors.add(:base, "original_amount and original_currency must be sent together")
      elsif currency.present? && currency.to_s.upcase != account.currency
        errors.add(:base, "send original_amount only when amount is in the account currency (#{account.currency})")
      end
    end
end
