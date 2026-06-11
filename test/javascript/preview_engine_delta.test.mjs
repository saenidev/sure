import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import {
  computeProjection,
  previewPeriods,
} from "../../app/javascript/forecast/preview_engine.mjs";

const fixturePath = path.join(
  path.dirname(fileURLToPath(import.meta.url)),
  "..",
  "fixtures",
  "files",
  "forecasts",
  "parity",
  "baseline_flat.json",
);
const input = JSON.parse(readFileSync(fixturePath, "utf8")).input;
// Island aa entries are ordinals into the island's assumptions array; the
// parity packet's assumption order stands in for it here.
const ordinalById = new Map(input.assumptions.map((a, i) => [a.id, i]));

// Converts computeProjection output into the island period shape the chart
// holds ({k, s, m: {nw,lc,inc,sp,db,pv,rd}, aa: [ordinals]}) so previewPeriods
// can be checked for self-consistency entirely in JS.
function islandShapedPeriods(projection) {
  return projection.map((p) => ({
    k: p.key,
    s: p.starts_on,
    m: {
      nw: p.metrics.net_worth,
      lc: p.metrics.liquid_cash,
      inc: p.metrics.income,
      sp: p.metrics.spending,
      db: p.metrics.debt_balance,
      pv: p.metrics.portfolio_value,
      rd: p.metrics.runway_days,
    },
    aa: p.active_assumption_ids.map((id) => ordinalById.get(id)),
  }));
}

function withSalaryOverride(overrideParams) {
  const clone = structuredClone(input);
  const salary = clone.assumptions.find((a) => a.id === "parity-salary-1");
  salary.params = { ...salary.params, ...overrideParams };
  return clone;
}

function assertPreviewMatches(preview, expected) {
  assert.equal(preview.length, expected.length, "period count");
  preview.forEach((period, i) => {
    const want = expected[i];
    assert.equal(period.k, want.k);
    assert.equal(period.s, want.s);
    for (const key of ["nw", "lc", "inc", "sp", "db", "pv"]) {
      assert.ok(
        Math.abs(Number(period.m[key]) - Number(want.m[key])) <= 0.01,
        `${want.k} ${key}: preview=${period.m[key]} full=${want.m[key]}`,
      );
    }
    // Runway is exact: both sides are JS floats over the same rounded inputs.
    assert.equal(period.m.rd, want.m.rd, `${want.k} rd`);
    assert.deepEqual(period.aa, want.aa, `${want.k} aa`);
  });
}

test("an amount override matches a full recompute", () => {
  const islandPeriods = islandShapedPeriods(computeProjection(input));
  const override = { amount: "7500.00" };

  const preview = previewPeriods(input, islandPeriods, "parity-salary-1", override, 0);
  const expected = islandShapedPeriods(computeProjection(withSalaryOverride(override)));

  assert.notEqual(preview, null);
  assertPreviewMatches(preview, expected);
});

test("a frequency override matches a full recompute and adjusts aa occupancy", () => {
  const islandPeriods = islandShapedPeriods(computeProjection(input));
  const override = { frequency: "annual" };

  const preview = previewPeriods(input, islandPeriods, "parity-salary-1", override, 0);
  const expected = islandShapedPeriods(computeProjection(withSalaryOverride(override)));

  assertPreviewMatches(preview, expected);
  // Guard against a vacuous pass: an annual salary skips most monthly
  // periods, so ordinal 0 must actually have been REMOVED somewhere.
  const dropped = preview.filter(
    (period, i) => !period.aa.includes(0) && islandPeriods[i].aa.includes(0),
  );
  assert.ok(dropped.length > 0, "expected periods that dropped ordinal 0");
});

test("untouched periods come back by identity (no float-flicker re-renders)", () => {
  const islandPeriods = islandShapedPeriods(computeProjection(input));
  const preview = previewPeriods(input, islandPeriods, "parity-salary-1", {}, 0);
  preview.forEach((period, i) => assert.equal(period, islandPeriods[i]));
});

test("returns null when the assumption is not in the packet", () => {
  const islandPeriods = islandShapedPeriods(computeProjection(input));
  assert.equal(
    previewPeriods(input, islandPeriods, "no-such-card", { amount: "1.00" }, 0),
    null,
  );
});

test("accepts the island packet-lite shape and agrees with the full packet", () => {
  const packetLite = {
    horizon: {
      starts_on: input.plan.horizon.starts_on,
      ends_on: input.plan.horizon.ends_on,
    },
    currency: input.plan.reporting_currency,
    opening: {
      lc: input.source_snapshot.opening_balances.liquid_cash,
      db: input.source_snapshot.opening_balances.debt_balance,
      pv: input.source_snapshot.opening_balances.portfolio_value,
    },
    assumptions: input.assumptions.map((a) => ({
      id: a.id,
      kind: a.kind,
      pv: true,
      params: a.params,
    })),
  };

  const islandPeriods = islandShapedPeriods(computeProjection(input));
  const override = { amount: "7000.00" };
  const fromFull = previewPeriods(input, islandPeriods, "parity-salary-1", override, 0);
  const fromLite = previewPeriods(packetLite, islandPeriods, "parity-salary-1", override, 0);
  assert.deepEqual(fromLite, fromFull);
});
