module Forecast
  class MoneyConverter
    MissingRate = Class.new(StandardError)
    ConvertedAmount = Data.define(:amount, :currency, :native_amount, :native_currency, :exchange_rate, :exchange_rate_date, :risk_flags)

    attr_reader :family, :as_of, :currency

    def initialize(family:, as_of:)
      @family = family
      @as_of = as_of
      @currency = family.currency
    end

    def convert(amount:, currency:, source:, as_of: self.as_of)
      conversion_date = as_of
      native_amount = amount.to_d
      native_currency = currency.presence || self.currency

      if native_amount.zero?
        return ConvertedAmount.new(
          amount: 0.to_d,
          currency: self.currency,
          native_amount: native_amount,
          native_currency: native_currency,
          exchange_rate: nil,
          exchange_rate_date: nil,
          risk_flags: []
        )
      end

      if native_currency == self.currency
        return ConvertedAmount.new(
          amount: native_amount,
          currency: self.currency,
          native_amount: native_amount,
          native_currency: native_currency,
          exchange_rate: 1.to_d,
          exchange_rate_date: conversion_date,
          risk_flags: []
        )
      end

      rate = ExchangeRate.find_or_fetch_rate(from: native_currency, to: self.currency, date: conversion_date, cache: false)
      raise MissingRate, "Missing FX rate #{native_currency}->#{self.currency} for #{conversion_date} while converting #{source}" if rate.blank?

      ConvertedAmount.new(
        amount: native_amount * rate.rate.to_d,
        currency: self.currency,
        native_amount: native_amount,
        native_currency: native_currency,
        exchange_rate: rate.rate.to_d,
        exchange_rate_date: rate.date,
        risk_flags: rate.date == conversion_date ? [] : [ { "type" => "stale_fx_rate", "source" => source, "from_currency" => native_currency, "to_currency" => self.currency, "requested_date" => conversion_date.iso8601, "rate_date" => rate.date.iso8601 } ]
      )
    end

    def snapshot_for(converted)
      {
        "currency" => converted.currency,
        "amount" => converted.amount.to_s,
        "native_amount" => converted.native_amount.to_s,
        "native_currency" => converted.native_currency,
        "exchange_rate" => converted.exchange_rate.to_s,
        "exchange_rate_date" => converted.exchange_rate_date&.iso8601,
        "risk_flags" => converted.risk_flags
      }
    end
  end
end
