# Settles Shortcut pending entries against the bank's posted transactions on
# the same account (SimpleFIN, Plaid, Lunch Flow or any other provider).
#
# Settling excludes the pending entry rather than merging it into the posted
# one, so both rows survive and link to each other:
#   pending extra["shortcut"]: pending=false, settled_by_entry_id, settled_by_transaction_id
#   posted  extra["shortcut"]: matched_pending_entry_id, matched_pending_transaction_id
#
# A pair settles only when it is unambiguous both ways: the posted entry is
# the pending entry's single best candidate, and the pending entry is the
# posted entry's single best rival. Ties left after comparing merchant names
# and dates stay pending for the user to resolve.
#
# Runs on every account sync (Account::Syncer, after provider imports) and
# right after a Shortcut posts a hint.
class ShortcutPending::Settler
  MAX_PASSES = 3

  attr_reader :account

  def initialize(account)
    @account = account
    @amount_cache = {}
  end

  # @return [Integer] number of pending entries settled
  def settle_open!
    settled = 0

    MAX_PASSES.times do
      pendings = open_pendings.to_a
      break if pendings.empty?

      posteds = posted_candidates(pendings).to_a
      progress = false

      pendings.dup.each do |pending|
        posted, match = unambiguous_match(pending, pendings, posteds)
        next unless posted && settle!(pending, posted, match: match)

        settled += 1
        progress = true
        pendings.delete(pending)
        posteds.delete(posted)
      end

      break unless progress
    end

    settled
  end

  # Links a pending entry to its posted transaction and excludes it.
  # Also used by the manual pending→posted merge.
  #
  # @return [Boolean] false when either side is already settled or matched
  def settle!(pending, posted, match:)
    settled = false

    Entry.transaction(requires_new: true) do
      pending.lock!
      posted.lock!
      pending_transaction = pending.entryable.lock!
      posted_transaction = posted.entryable.lock!

      pending_data = ShortcutPending.data(pending_transaction)
      posted_data = ShortcutPending.data(posted_transaction)

      if pending_data["settled_by_entry_id"].blank? && posted_data["matched_pending_entry_id"].blank?
        pending_transaction.update!(extra: pending_transaction.extra.merge(
          ShortcutPending::SOURCE => pending_data.merge(
            "pending" => false,
            "settled_by_entry_id" => posted.id,
            "settled_by_transaction_id" => posted_transaction.id,
            "settled_at" => Time.current.iso8601,
            "settlement_match" => match
          )
        ))
        pending.update!(excluded: true)

        posted_transaction.update!(extra: (posted_transaction.extra || {}).merge(
          ShortcutPending::SOURCE => posted_data.merge(
            "matched_pending_entry_id" => pending.id,
            "matched_pending_transaction_id" => pending_transaction.id
          )
        ))
        posted.touch

        settled = true
      end
    end

    if settled
      Rails.logger.info("Settled shortcut pending entry #{pending.id} (#{pending.name}) by posted entry #{posted.id} (#{match})")
    end

    settled
  end

  private

    def open_pendings
      account.entries
        .joins("INNER JOIN transactions ON transactions.id = entries.entryable_id AND entries.entryable_type = 'Transaction'")
        .where(source: ShortcutPending::SOURCE, excluded: false)
        .where("(transactions.extra -> 'shortcut' ->> 'pending')::boolean = true")
        .includes(:entryable)
        .order(:date, :created_at)
    end

    # Posted bank transactions that could settle any of the given pendings.
    def posted_candidates(pendings)
      dates = pendings.map(&:date)

      account.entries
        .joins("INNER JOIN transactions ON transactions.id = entries.entryable_id AND entries.entryable_type = 'Transaction'")
        .where(excluded: false)
        .where(date: (dates.min - ShortcutPending::DAYS_BEFORE.days)..(dates.max + ShortcutPending::EXACT_DAYS_AFTER.days))
        .where.not(source: nil)
        .where.not(source: ShortcutPending::SOURCE)
        .where(Transaction::NOT_PENDING_SQL)
        .where("transactions.extra -> 'shortcut' ->> 'matched_pending_entry_id' IS NULL")
        .includes(:entryable)
    end

    # @return [Array(Entry, String), nil] the posted entry and the match type
    def unambiguous_match(pending, pendings, posteds)
      candidates, match = candidates_for(pending, posteds)
      chosen = narrow(candidates, name: pending.name, date: pending.date)
      return unless chosen

      rivals = pendings.select { |other| candidates_for(other, posteds).first.include?(chosen) }
      return unless narrow(rivals, name: chosen.name, date: chosen.date) == pending

      [ chosen, match ]
    end

    # Exact (or FX-tolerant) amount matches first; tips only when there are none.
    def candidates_for(pending, posteds)
      exact = posteds.select { |posted| amount_match?(pending, posted) }
      return [ exact, estimated?(pending, exact.first) ? "fx" : "exact" ] if exact.any?

      [ posteds.select { |posted| tip_match?(pending, posted) }, "tip" ]
    end

    # Picks one entry by merchant name, then by closest date. nil when tied.
    def narrow(entries, name:, date:)
      return entries.first if entries.size <= 1

      named = entries.select { |entry| ShortcutPending.names_match?(entry.name, name) }
      entries = named if named.any?
      return entries.first if entries.size == 1

      by_distance = entries.group_by { |entry| (entry.date - date).abs }
      closest = by_distance[by_distance.keys.min]
      closest.size == 1 ? closest.first : nil
    end

    def amount_match?(pending, posted)
      return false unless within_days?(pending, posted, ShortcutPending::EXACT_DAYS_AFTER)

      expected = amount_in(pending, posted.currency)
      return false unless expected && same_sign?(expected, posted.amount)

      tolerance = estimated?(pending, posted) ? ShortcutPending::FX_TOLERANCE : 0
      (posted.amount.abs - expected.abs).abs <= expected.abs * tolerance
    end

    # A tip raises the posted amount above the authorized one. Needs a
    # matching merchant name as well.
    def tip_match?(pending, posted)
      return false unless pending.amount.positive?
      return false unless within_days?(pending, posted, ShortcutPending::TIP_DAYS_AFTER)

      expected = amount_in(pending, posted.currency)
      return false unless expected && same_sign?(expected, posted.amount)

      fx = estimated?(pending, posted) ? ShortcutPending::FX_TOLERANCE : 0
      low = expected.abs * (1 - fx)
      high = expected.abs * (1 + ShortcutPending::TIP_TOLERANCE) * (1 + fx)
      return false unless posted.amount.abs.between?(low, high)

      ShortcutPending.names_match?(pending.name, posted.name)
    end

    def within_days?(pending, posted, days_after)
      posted.date.between?(pending.date - ShortcutPending::DAYS_BEFORE.days, pending.date + days_after.days)
    end

    def same_sign?(a, b)
      a.positive? == b.positive?
    end

    # The pending amount is an estimate when we converted it from a foreign
    # currency (or still have to).
    def estimated?(pending, posted)
      conversion = ShortcutPending.data(pending.entryable)["conversion"]
      conversion.in?(%w[converted unconverted]) || (posted && posted.currency != pending.currency)
    end

    # The pending amount in the posted currency. A hint stored unconverted
    # (no rate when it arrived) is converted now, if a rate exists by then.
    def amount_in(pending, currency)
      return pending.amount if pending.currency == currency

      @amount_cache[[ pending.id, currency ]] ||= begin
        Money.new(pending.amount, pending.currency).exchange_to(currency, date: pending.date).amount
      rescue Money::ConversionError
        false
      end
      @amount_cache[[ pending.id, currency ]] || nil
    end
end
