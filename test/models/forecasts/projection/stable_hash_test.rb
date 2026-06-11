# frozen_string_literal: true

require "test_helper"

# Covers the injective canonical encoder behind `Forecasts::Projection.stable_hash`.
#
# This digest backs `input_packet_hash`, `source_snapshot_hash`,
# `scenario_stack_hash`, and the `result_hash` the recompute coordinator uses
# for cache keying, coalescing, and stale-result protection. User-controlled
# strings (account names, scenario layer_ids) flow into the hashed payload, so a
# canonicalization collision could let two structurally distinct inputs share a
# cache and serve a wrong/stale projection.
#
# These tests lock the two contract properties:
#   1. Determinism: same input -> same hash (order-independent for hashes).
#   2. Injectivity: structurally distinct inputs -> distinct hashes.
class Forecasts::Projection::StableHashTest < ActiveSupport::TestCase
  # --- Determinism (same input -> same hash) -------------------------------

  test "stable_hash is deterministic for equal inputs" do
    a = { b: 1, a: 2, nested: { y: [ 1, 2 ], x: "v" } }
    b = { a: 2, b: 1, nested: { x: "v", y: [ 1, 2 ] } }

    assert_equal Forecasts::Projection.stable_hash(a),
                 Forecasts::Projection.stable_hash(b),
                 "hash digest must be independent of key insertion order"
  end

  test "stable_hash preserves array order (order is meaningful)" do
    refute_equal Forecasts::Projection.stable_hash(layer_ids: %w[l1 l2]),
                 Forecasts::Projection.stable_hash(layer_ids: %w[l2 l1])
  end

  test "stable_hash returns a hex SHA256 digest" do
    digest = Forecasts::Projection.stable_hash(v: 1)
    assert_match(/\A[0-9a-f]{64}\z/, digest)
  end

  # --- Injectivity (distinct inputs -> distinct hashes) --------------------

  test "key=value injection in a string value does not collide with extra keys" do
    # The old encoder joined entries as `key=value` with comma separators and
    # rendered scalars via to_s, so a value containing the delimiters collided
    # with a structurally different hash.
    injected = { a: "1,b=2" }
    distinct = { a: "1", b: "2" }

    refute_equal Forecasts::Projection.stable_hash(injected),
                 Forecasts::Projection.stable_hash(distinct),
                 "a value containing delimiters must not collide with extra keys"
  end

  test "integer and string scalars of the same characters do not collide" do
    refute_equal Forecasts::Projection.stable_hash(v: 1),
                 Forecasts::Projection.stable_hash(v: "1"),
                 "an integer value must not collide with its string form"
  end

  test "nil and the literal string 'null' do not collide" do
    refute_equal Forecasts::Projection.stable_hash(v: nil),
                 Forecasts::Projection.stable_hash(v: "null"),
                 "nil must not collide with the literal string 'null'"
  end

  test "array boundaries are injective (joined vs split elements)" do
    joined = { layer_ids: [ "l1,l2" ] }
    split = { layer_ids: [ "l1", "l2" ] }

    refute_equal Forecasts::Projection.stable_hash(joined),
                 Forecasts::Projection.stable_hash(split),
                 "a single joined string must not collide with split array elements"
  end

  test "boolean and string scalars of the same characters do not collide" do
    refute_equal Forecasts::Projection.stable_hash(v: true),
                 Forecasts::Projection.stable_hash(v: "true")
    refute_equal Forecasts::Projection.stable_hash(v: false),
                 Forecasts::Projection.stable_hash(v: "false")
  end

  test "symbol and string values of the same characters do not collide" do
    refute_equal Forecasts::Projection.stable_hash(v: :net),
                 Forecasts::Projection.stable_hash(v: "net")
  end

  test "empty array, empty hash, empty string, and nil do not collide" do
    digests = [
      Forecasts::Projection.stable_hash(v: []),
      Forecasts::Projection.stable_hash(v: {}),
      Forecasts::Projection.stable_hash(v: ""),
      Forecasts::Projection.stable_hash(v: nil)
    ]

    assert_equal digests.length, digests.uniq.length,
      "empty collections, empty string, and nil must all encode distinctly"
  end

  test "key name and value text cannot be confused across the boundary" do
    # {ab: "c"} and {a: "bc"} share the same flattened characters; length
    # prefixing the key keeps them distinct.
    refute_equal Forecasts::Projection.stable_hash(ab: "c"),
                 Forecasts::Projection.stable_hash(a: "bc")
  end
end
