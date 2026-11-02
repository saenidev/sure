# A Money store that looks each (from, to, date) rate up once.
#
# Syncs convert the same pair on the same date many times over: every held
# security's price on every day of the account's history, every holding row.
# ExchangeRate.find_or_fetch_rate costs one or two queries per call, and a
# provider request when both miss. Misses are kept too, so a date the provider
# has no rate for is asked for once rather than once per security.
#
# Lives as long as the cache object that owns it (one sync), so rates written
# by other processes in the meantime are not seen until the next sync.
class ExchangeRate::MemoizedStore
  def initialize(store = ExchangeRate)
    @store = store
    @rates = {}
  end

  def find_or_fetch_rate(from:, to:, date: Date.current)
    key = [ from, to, date ]
    return @rates[key] if @rates.key?(key)

    @rates[key] = @store.find_or_fetch_rate(from: from, to: to, date: date)
  end
end
