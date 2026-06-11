import { test } from "node:test";
import assert from "node:assert/strict";
import {
  enginePolicy,
  normalizeFormValues,
} from "../../app/javascript/forecast/form_params.mjs";

test("enginePolicy maps fixed_rate + percentage to a fractional annual_percentage", () => {
  assert.deepEqual(enginePolicy("fixed_rate", "3.0"), { type: "annual_percentage", rate: 0.03 });
  assert.deepEqual(enginePolicy("fixed_rate", "2.5"), { type: "annual_percentage", rate: 0.025 });
  assert.deepEqual(enginePolicy("fixed_rate", "0"), { type: "annual_percentage", rate: 0 });
});

test("enginePolicy maps everything else to no growth", () => {
  assert.deepEqual(enginePolicy("flat", "3.0"), { type: "none" });
  assert.deepEqual(enginePolicy("fixed_rate", ""), { type: "none" }); // rate blank
  assert.deepEqual(enginePolicy("fixed_rate", "   "), { type: "none" }); // whitespace == blank
  assert.deepEqual(enginePolicy("fixed_rate", null), { type: "none" });
  assert.deepEqual(enginePolicy(null, null), { type: "none" });
  assert.deepEqual(enginePolicy("", "3.0"), { type: "none" });
});

test("enginePolicy passes an already-engine-shaped hash through untouched", () => {
  const policy = { type: "annual_percentage", rate: 0.04 };
  assert.equal(enginePolicy(policy, "9.9"), policy);
});

test("normalizeFormValues maps present scalar fields as strings", () => {
  assert.deepEqual(
    normalizeFormValues({ amount: "6500.00", frequency: "monthly", currency: "USD", net_ratio: "0.78" }),
    { amount: "6500.00", frequency: "monthly", currency: "USD", net_ratio: "0.78" },
  );
  assert.deepEqual(normalizeFormValues({ amount: 6500 }), { amount: "6500" });
});

test("normalizeFormValues skips absent and blank scalar fields", () => {
  // Absent keys never clobber the packet's stored params; blank values are
  // mid-typing states, not overrides.
  assert.deepEqual(normalizeFormValues({}), {});
  assert.deepEqual(normalizeFormValues({ amount: "" }), {});
  assert.deepEqual(normalizeFormValues({ frequency: "weekly", net_ratio: "" }), { frequency: "weekly" });
});

test("normalizeFormValues folds policy + rate pairs through enginePolicy", () => {
  assert.deepEqual(
    normalizeFormValues({ growth_policy: "fixed_rate", growth_rate: "3.0" }),
    { growth_policy: { type: "annual_percentage", rate: 0.03 } },
  );
  assert.deepEqual(
    normalizeFormValues({ inflation_policy: "fixed_rate", inflation_rate: "2.5" }),
    { inflation_policy: { type: "annual_percentage", rate: 0.025 } },
  );
  assert.deepEqual(
    normalizeFormValues({ growth_policy: "flat", growth_rate: "3.0" }),
    { growth_policy: { type: "none" } },
  );
  // A rate WITHOUT its policy key produces no override (mirrors PacketBuilder
  // #policy_params, which is keyed on the policy's presence).
  assert.deepEqual(normalizeFormValues({ growth_rate: "3.0" }), {});
});

test("normalizeFormValues handles a full salary drawer payload", () => {
  assert.deepEqual(
    normalizeFormValues({
      amount: "6500.00",
      frequency: "monthly",
      currency: "USD",
      net_ratio: "0.78",
      growth_policy: "fixed_rate",
      growth_rate: "3.0",
    }),
    {
      amount: "6500.00",
      frequency: "monthly",
      currency: "USD",
      net_ratio: "0.78",
      growth_policy: { type: "annual_percentage", rate: 0.03 },
    },
  );
});
