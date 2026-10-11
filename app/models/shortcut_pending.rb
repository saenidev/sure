# A purchase hint posted through the API by an iPhone Shortcut: an Apple Pay
# tap (Wallet trigger) or a card's per-purchase alert (email/message trigger).
#
# The hint is stored as a pending transaction with source "shortcut", its
# metadata under transaction.extra["shortcut"]. A tap and an alert for the
# same purchase fold into one entry (Recorder), and the bank's posted version
# settles it later (Settler): the hint is excluded, and both sides record the
# link, so the purchase counts once and API readers can follow what happened.
module ShortcutPending
  SOURCE = "shortcut".freeze
  ORIGINS = %w[apple_pay bank_alert].freeze

  # A tap and an alert this close together, with the same amount and
  # different origins, are the same purchase.
  SAME_PURCHASE_WINDOW = 15.minutes

  # Converted amounts (a tap abroad, converted at our rate) match the bank's
  # amount within this fraction either way: the card network's rate differs.
  FX_TOLERANCE = BigDecimal("0.05")

  # A posted amount up to this fraction above the hint is a tip. A single,
  # unambiguous candidate with a matching name settles automatically.
  TIP_TOLERANCE = BigDecimal("0.25")

  # The bank may date the posting one day *before* the hint: a tap in Korea
  # (UTC+9) carries the next calendar day relative to a US posting date.
  DAYS_BEFORE = 1
  EXACT_DAYS_AFTER = 8
  TIP_DAYS_AFTER = 3

  # Tokens that say nothing about the merchant ("SQ *BLUE BOTTLE", "TST* ...").
  NAME_NOISE_TOKENS = %w[sq tst pos the inc llc ltd co corp store purchase payment card debit pp paypal apple pay].freeze

  module_function

  # @return [Hash] the shortcut metadata on a transaction (empty when absent)
  def data(transaction)
    extra = transaction&.extra
    value = extra.is_a?(Hash) ? extra[SOURCE] : nil
    value.is_a?(Hash) ? value : {}
  end

  # Loose merchant-name comparison between a phone hint ("Blue Bottle Coffee")
  # and a bank descriptor ("SQ *BLUE BOTTLE 1234"). Used to pick between
  # candidates and to accept tips, never as the only signal.
  def names_match?(a, b)
    tokens_a = name_tokens(a)
    tokens_b = name_tokens(b)
    return false if tokens_a.empty? || tokens_b.empty?
    return true if tokens_a.first == tokens_b.first

    joined_a = tokens_a.join
    joined_b = tokens_b.join
    joined_a.start_with?(joined_b) || joined_b.start_with?(joined_a)
  end

  def name_tokens(name)
    name.to_s.downcase.delete("'’").split(/[^\p{L}\p{N}]+/).reject do |token|
      token.length < 2 || token.match?(/\A\d+\z/) || NAME_NOISE_TOKENS.include?(token)
    end
  end
end
