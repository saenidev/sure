import { test } from "node:test";
import assert from "node:assert/strict";
import {
  addDays,
  addMonths,
  clampWindow,
  compareDates,
  daysInMonth,
  elapsedYears,
  monthCount,
  occurrenceDates,
  parseDate,
  periodKey,
  round2,
  toISO,
} from "../../app/javascript/forecast/preview_engine.mjs";

const d = (iso) => parseDate(iso);
const isoList = (dates) => dates.map(toISO);

test("parseDate / toISO round-trip and edge inputs", () => {
  assert.deepEqual(parseDate("2026-01-31"), { y: 2026, m: 1, d: 31 });
  assert.equal(toISO({ y: 2026, m: 1, d: 31 }), "2026-01-31");
  // Packet values can be timestamps (snapshot as_of); only the date part counts,
  // mirroring Ruby Date.parse.
  assert.deepEqual(parseDate("2026-01-01T00:00:00Z"), { y: 2026, m: 1, d: 1 });
  // Ruby parse_date returns nil for nil/"" — mirror as null.
  assert.equal(parseDate(null), null);
  assert.equal(parseDate(""), null);
  assert.throws(() => parseDate("not-a-date"));
});

test("daysInMonth handles leap rules deterministically", () => {
  assert.equal(daysInMonth(2026, 1), 31);
  assert.equal(daysInMonth(2026, 2), 28);
  assert.equal(daysInMonth(2028, 2), 29); // leap
  assert.equal(daysInMonth(2000, 2), 29); // divisible by 400 -> leap
  assert.equal(daysInMonth(2100, 2), 28); // century non-leap
  assert.equal(daysInMonth(2026, 4), 30);
});

test("addMonths clamps the day to month end like Ruby Date#>>", () => {
  assert.equal(toISO(addMonths(d("2026-01-31"), 1)), "2026-02-28");
  assert.equal(toISO(addMonths(d("2028-01-31"), 1)), "2028-02-29"); // leap Feb
  assert.equal(toISO(addMonths(d("2026-01-31"), 3)), "2026-04-30");
  assert.equal(toISO(addMonths(d("2026-01-31"), 0)), "2026-01-31");
  assert.equal(toISO(addMonths(d("2026-12-15"), 1)), "2027-01-15"); // year wrap
  assert.equal(toISO(addMonths(d("2026-01-01"), 13)), "2027-02-01");
});

test("addDays walks calendar days across month/year boundaries", () => {
  assert.equal(toISO(addDays(d("2026-01-30"), 14)), "2026-02-13");
  assert.equal(toISO(addDays(d("2026-12-31"), 1)), "2027-01-01");
  assert.equal(toISO(addDays(d("2028-02-28"), 1)), "2028-02-29"); // leap
});

test("compareDates orders by (y, m, d)", () => {
  assert.ok(compareDates(d("2026-01-31"), d("2026-02-01")) < 0);
  assert.ok(compareDates(d("2027-01-01"), d("2026-12-31")) > 0);
  assert.equal(compareDates(d("2026-06-15"), d("2026-06-15")), 0);
});

test("periodKey formats YYYY-MM", () => {
  assert.equal(periodKey(d("2026-01-31")), "2026-01");
  assert.equal(periodKey(d("2026-11-01")), "2026-11");
});

test("monthly occurrences advance from the ANCHOR — no end-of-month drift", () => {
  // Ruby: advance(anchor, freq, index) = anchor >> index. A previous-date walk
  // would decay Jan 31 -> Feb 28 -> Mar 28; the anchor walk restores Mar 31.
  assert.deepEqual(isoList(occurrenceDates("monthly", d("2026-01-31"), d("2026-06-30"))), [
    "2026-01-31",
    "2026-02-28",
    "2026-03-31",
    "2026-04-30",
    "2026-05-31",
    "2026-06-30",
  ]);
});

test("weekly / biweekly / quarterly / annual walks", () => {
  assert.deepEqual(isoList(occurrenceDates("biweekly", d("2026-01-02"), d("2026-02-15"))), [
    "2026-01-02",
    "2026-01-16",
    "2026-01-30",
    "2026-02-13",
  ]);
  assert.deepEqual(isoList(occurrenceDates("weekly", d("2026-01-03"), d("2026-01-20"))), [
    "2026-01-03",
    "2026-01-10",
    "2026-01-17",
  ]);
  assert.deepEqual(isoList(occurrenceDates("quarterly", d("2026-01-31"), d("2026-12-31"))), [
    "2026-01-31",
    "2026-04-30",
    "2026-07-31",
    "2026-10-31",
  ]);
  // "annual" and "yearly" are aliases (Ruby case "annual", "yearly").
  assert.deepEqual(isoList(occurrenceDates("annual", d("2028-02-29"), d("2030-12-31"))), [
    "2028-02-29",
    "2029-02-28",
    "2030-02-28",
  ]);
  assert.deepEqual(
    isoList(occurrenceDates("yearly", d("2026-05-01"), d("2027-05-01"))),
    ["2026-05-01", "2027-05-01"],
  );
});

test("one_time yields a single occurrence; an empty window yields none", () => {
  assert.deepEqual(isoList(occurrenceDates("one_time", d("2026-03-15"), d("2029-01-01"))), [
    "2026-03-15",
  ]);
  assert.deepEqual(occurrenceDates("one_time", d("2026-03-15"), d("2026-03-14")), []);
  assert.deepEqual(occurrenceDates("monthly", d("2026-03-15"), d("2026-03-14")), []);
});

test("occurrenceDates throws on an unknown frequency", () => {
  assert.throws(
    () => occurrenceDates("fortnightly", d("2026-01-01"), d("2026-03-01")),
    /Unsupported frequency/,
  );
});

test("elapsedYears counts whole years against the window-start anniversary", () => {
  const start = d("2026-03-15");
  assert.equal(elapsedYears(start, d("2026-03-15")), 0); // same day
  assert.equal(elapsedYears(start, d("2026-12-31")), 0); // same year
  assert.equal(elapsedYears(start, d("2027-03-14")), 0); // day before anniversary
  assert.equal(elapsedYears(start, d("2027-03-15")), 1); // anniversary
  assert.equal(elapsedYears(start, d("2027-03-16")), 1);
  assert.equal(elapsedYears(start, d("2028-02-29")), 1); // month before anniversary
  assert.equal(elapsedYears(start, d("2030-03-15")), 4);
  // Occurrence before the start never goes negative (Ruby: return 0 if years <= 0).
  assert.equal(elapsedYears(start, d("2025-06-01")), 0);
});

test("elapsedYears Feb-29 anchor falls back to Feb 28 in non-leap occurrence years", () => {
  const start = d("2028-02-29");
  assert.equal(elapsedYears(start, d("2029-02-27")), 0); // before the fallback anniversary
  assert.equal(elapsedYears(start, d("2029-02-28")), 1); // non-leap: anniversary is Feb 28
  assert.equal(elapsedYears(start, d("2029-03-01")), 1);
  assert.equal(elapsedYears(start, d("2032-02-28")), 3); // leap year: anniversary stays Feb 29
  assert.equal(elapsedYears(start, d("2032-02-29")), 4);
});

test("clampWindow clamps anchors into the horizon and nulls empty windows", () => {
  const horizon = { start: d("2026-01-01"), end: d("2029-01-01") };
  // Null anchors fall back to the horizon bounds (Ruby occurrence_window).
  assert.deepEqual(clampWindow(null, null, horizon), [d("2026-01-01"), d("2029-01-01")]);
  // Outside anchors clamp in.
  assert.deepEqual(clampWindow(d("2025-06-01"), d("2030-06-01"), horizon), [
    d("2026-01-01"),
    d("2029-01-01"),
  ]);
  // Inside anchors pass through.
  assert.deepEqual(clampWindow(d("2026-03-15"), d("2028-06-30"), horizon), [
    d("2026-03-15"),
    d("2028-06-30"),
  ]);
  // end < start after clamping -> null (expander emits no flows).
  assert.equal(clampWindow(d("2027-01-01"), d("2026-12-31"), horizon), null);
  // start anchor beyond the horizon end -> null.
  assert.equal(clampWindow(d("2030-01-01"), null, horizon), null);
});

test("monthCount is span + 1: the horizon-end month is INCLUSIVE", () => {
  // 2026-01-01..2029-01-01 is a 36-month span but simulates 37 periods
  // (2026-01..2029-01) — see PeriodSimulator#month_count.
  assert.equal(monthCount({ start: d("2026-01-01"), end: d("2029-01-01") }), 37);
  assert.equal(monthCount({ start: d("2026-01-01"), end: d("2026-01-31") }), 1);
  assert.equal(monthCount({ start: d("2026-01-15"), end: d("2026-03-01") }), 3);
  assert.equal(monthCount({ start: d("2026-01-01"), end: d("2056-01-01") }), 361); // 30y worst case
  // Degenerate horizons still simulate at least one period (Ruby [span + 1, 1].max).
  assert.equal(monthCount({ start: d("2026-03-01"), end: d("2026-01-01") }), 1);
});

test("round2 rounds half-up to cents for positive amounts", () => {
  assert.equal(round2(1.005), 1.01); // the classic float trap; EPSILON nudge fixes it
  assert.equal(round2(2.675), 2.68);
  assert.equal(round2(0.1 + 0.2), 0.3);
  assert.equal(round2(6000), 6000);
  assert.equal(round2(4680.000000000001), 4680);
  assert.equal(round2(0), 0);
});
