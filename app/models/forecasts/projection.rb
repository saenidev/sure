# frozen_string_literal: true

require "digest"

module Forecasts
  # Namespace for the pure Forecast V2 projection engine value objects and
  # entrypoint. Everything under `Forecasts::Projection::*` is pure: no
  # ActiveRecord, no jobs, no providers, no UI formatting, and deterministic for
  # the same input. Money is serialized as decimal strings plus currency
  # context, never floats. The run/as-of date is threaded explicitly through the
  # packet; nothing here reads `Date.current`.
  module Projection
    module_function

    # Recursively converts a hash (string- or symbol-keyed) into a frozen,
    # deeply symbolized structure. Used so packets/results constructed from JSON
    # or from Ruby hashes normalize to one canonical in-memory shape.
    def deep_symbolize(value)
      case value
      when Hash
        value.each_with_object({}) do |(key, val), memo|
          memo[key.to_sym] = deep_symbolize(val)
        end
      when Array
        value.map { |element| deep_symbolize(element) }
      else
        value
      end
    end

    # Recursively freezes a value (and its contents) so value objects are
    # genuinely immutable after construction.
    def deep_freeze(value)
      case value
      when Hash
        value.each_value { |val| deep_freeze(val) }
        value.freeze
      when Array
        value.each { |element| deep_freeze(element) }
        value.freeze
      else
        value.freeze
      end
    end

    # Produces a stable SHA256 digest of an arbitrary nested structure that is
    # independent of hash key insertion order. This is the basis for the
    # deterministic packet/snapshot/scenario hashes the recompute coordinator
    # relies on for stale-result protection.
    def stable_hash(value)
      Digest::SHA256.hexdigest(canonicalize(value))
    end

    # Builds a canonical, order-independent string representation of a nested
    # structure. Hash keys are sorted; arrays preserve order (order is
    # meaningful for things like scenario layer stacks).
    def canonicalize(value)
      case value
      when Hash
        inner = value
          .sort_by { |key, _| key.to_s }
          .map { |key, val| "#{key}=#{canonicalize(val)}" }
          .join(",")
        "{#{inner}}"
      when Array
        "[#{value.map { |element| canonicalize(element) }.join(',')}]"
      when nil
        "null"
      else
        value.to_s
      end
    end
  end
end
