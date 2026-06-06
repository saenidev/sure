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

    # Builds a canonical, order-independent, and INJECTIVE encoding of a nested
    # structure. Hash keys are sorted; arrays preserve order (order is
    # meaningful for things like scenario layer stacks).
    #
    # Injectivity matters: this encoding backs `input_packet_hash`,
    # `source_snapshot_hash`, `scenario_stack_hash`, and the `result_hash` the
    # recompute coordinator uses for cache keying, coalescing, and stale-result
    # protection. User-controlled strings (account names, scenario layer_ids)
    # flow into the hashed payload, so structurally distinct inputs MUST encode
    # to distinct strings or two different inputs could share a cache and serve
    # a wrong/stale projection.
    #
    # To guarantee injectivity the encoding tags every scalar with its type and
    # length-prefixes strings (and hash keys), so no concatenation of delimiters
    # or values can be reinterpreted as a different structure. Examples of pairs
    # that must NOT collide (and now do not):
    #   {a: "1,b=2"}                vs  {a: "1", b: "2"}
    #   {v: 1}                      vs  {v: "1"}
    #   {v: nil}                    vs  {v: "null"}
    #   {layer_ids: ["l1", "l2"]}   vs  {layer_ids: ["l1,l2"]}
    #
    # The same input always encodes to the same string (key order independent,
    # array order preserved), so "same input -> same hash" is retained.
    def canonicalize(value)
      case value
      when nil
        "n"
      when true
        "b:t"
      when false
        "b:f"
      when Integer
        "i:#{value}"
      when Float
        # Money is serialized as decimal strings, never floats; encoding them
        # here is purely defensive so a stray float can never collide with an
        # integer or string of the same digits.
        "f:#{value}"
      when Symbol
        # Distinguish a symbol value from a string of the same characters.
        str = value.to_s
        "y:#{str.bytesize}:#{str}"
      when Array
        "a:#{value.length}:[#{value.map { |element| canonicalize(element) }.join}]"
      when Hash
        inner = value
          .sort_by { |key, _| key.to_s }
          .map { |key, val| "#{canonicalize_key(key)}#{canonicalize(val)}" }
          .join
        "h:#{value.length}:{#{inner}}"
      else
        str = value.to_s
        "s:#{str.bytesize}:#{str}"
      end
    end

    # Encodes a hash key (always treated as a length-prefixed string) so that a
    # key/value boundary can never be confused with key/value content.
    def canonicalize_key(key)
      str = key.to_s
      "k:#{str.bytesize}:#{str}"
    end
  end
end
