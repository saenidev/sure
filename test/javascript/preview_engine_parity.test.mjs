import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, readdirSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import {
  UNBOUNDED_RUNWAY_DAYS,
  computeProjection,
  expandAssumption,
  parseDate,
} from "../../app/javascript/forecast/preview_engine.mjs";

// Dual-engine parity budget (spec §11a): per money metric per period,
// |js - ruby| <= max($1, 0.01% of |ruby|). Runway tolerates ±1 day — float vs
// BigDecimal can land on opposite sides of an exact floor boundary.
const MONEY_ABS_TOLERANCE = 1.0;
const MONEY_REL_TOLERANCE = 0.0001;
const MONEY_METRICS = [
  "net_worth",
  "liquid_cash",
  "income",
  "spending",
  "debt_balance",
  "portfolio_value",
];

const parityDir = path.join(
  path.dirname(fileURLToPath(import.meta.url)),
  "..",
  "fixtures",
  "files",
  "forecasts",
  "parity",
);

const fixtureFiles = readdirSync(parityDir)
  .filter((name) => name.endsWith(".json"))
  .sort();

function loadFixture(file) {
  return JSON.parse(readFileSync(path.join(parityDir, file), "utf8"));
}

function assertMoneyClose(actual, expectedString, label) {
  const expected = Number(expectedString);
  const tolerance = Math.max(MONEY_ABS_TOLERANCE, Math.abs(expected) * MONEY_REL_TOLERANCE);
  assert.ok(
    Math.abs(actual - expected) <= tolerance,
    `${label}: js=${actual} ruby=${expectedString} tolerance=${tolerance}`,
  );
}

test("parity fixture directory is populated", () => {
  assert.ok(
    fixtureFiles.length >= 3,
    `expected >= 3 parity fixtures in ${parityDir}, found ${fixtureFiles.length}`,
  );
});

// Every *.json in the parity dir, sorted, skipping NONE — a new fixture is
// automatically under parity discipline the moment the rake task writes it.
for (const file of fixtureFiles) {
  test(`parity: ${file}`, () => {
    const fixture = loadFixture(file);
    const periods = computeProjection(fixture.input);

    assert.equal(periods.length, fixture.expected.period_count, `${file}: period_count`);
    assert.equal(periods.length, fixture.expected.periods.length, `${file}: expected series length`);

    periods.forEach((period, i) => {
      const expected = fixture.expected.periods[i];
      const where = `${file} ${expected.k}`;

      assert.equal(period.key, expected.k, `${where}: key`);
      assert.equal(period.starts_on, expected.s, `${where}: starts_on`);

      for (const metric of MONEY_METRICS) {
        assertMoneyClose(period.metrics[metric], expected.m[metric], `${where}: ${metric}`);
      }

      assert.ok(
        Math.abs(period.metrics.runway_days - expected.m.runway_days) <= 1,
        `${where}: runway_days js=${period.metrics.runway_days} ruby=${expected.m.runway_days}`,
      );

      assert.deepEqual(
        period.active_assumption_ids,
        expected.active_assumption_ids,
        `${where}: active_assumption_ids`,
      );
    });
  });
}

// Perf tripwire: the preview engine runs per keystroke in the drawer, so the
// 30-year worst case must stay inside the same <150ms budget as the Ruby engine.
test("computeProjection stays under 150ms on the 30-year fixture", () => {
  const file = "frequencies_30y.json";
  assert.ok(fixtureFiles.includes(file), `${file} missing from ${parityDir}`);
  const fixture = loadFixture(file);

  computeProjection(fixture.input); // warm-up run: keep JIT/module costs out of the measurement
  const startedAt = performance.now();
  computeProjection(fixture.input);
  const elapsedMs = performance.now() - startedAt;

  assert.ok(elapsedMs < 150, `computeProjection took ${elapsedMs.toFixed(1)}ms (budget 150ms)`);
});

// --- expandAssumption unit edges not reachable through the fixtures ---------

const horizon = { start: parseDate("2026-01-01"), end: parseDate("2026-06-01") };

test("a 0-amount occurrence still marks the period occupied (mirrors Ruby trace rows)", () => {
  const flows = expandAssumption(
    {
      id: "a1",
      kind: "salary",
      status: "active",
      params: { amount: "0.00", frequency: "monthly", start_anchor: { type: "date", on: "2026-01-01" } },
    },
    horizon,
  );
  assert.equal(flows.size, 6);
  assert.deepEqual(flows.get("2026-03"), { income: 0, spending: 0 });
});

test("an unknown kind expands to an empty Map (registry preview flag gates upstream)", () => {
  const flows = expandAssumption(
    { id: "a1", kind: "windfall", status: "active", params: { amount: "100.00" } },
    horizon,
  );
  assert.equal(flows.size, 0);
});

test("a milestone anchor throws — the island must pre-resolve milestones to dates", () => {
  assert.throws(
    () =>
      expandAssumption(
        {
          id: "a1",
          kind: "salary",
          status: "active",
          params: { amount: "100.00", start_anchor: { type: "milestone", milestone_key: "m-1" } },
        },
        horizon,
      ),
    /milestone/,
  );
});

test("the runway sentinel is exported for the chart's unbounded display", () => {
  assert.equal(UNBOUNDED_RUNWAY_DAYS, 99999);
});

test("period starts_on is the beginning of month even for a mid-month horizon start", () => {
  // Ruby period_windows: starts_on = month_start.beginning_of_month, while the
  // walk itself uses month_start = horizon_start >> i (possibly mid-month).
  const fixture = loadFixture("baseline_flat.json");
  const input = structuredClone(fixture.input);
  input.plan.horizon.starts_on = "2026-01-15";

  const periods = computeProjection(input);
  assert.equal(periods[0].key, "2026-01");
  assert.equal(periods[0].starts_on, "2026-01-01");
  assert.equal(periods[1].starts_on, "2026-02-01");
  assert.equal(periods.length, 37); // same span months -> same inclusive count
});
