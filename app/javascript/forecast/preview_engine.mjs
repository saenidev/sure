// Forecast preview engine (phase 4, spec §11a) — the JS semantic mirror of
// the pure Ruby projection engine:
//   app/models/forecasts/projection/expanders/base.rb   (dates, walk, window)
//   app/models/forecasts/projection/expanders/salary.rb
//   app/models/forecasts/projection/expanders/living_expense.rb
//   app/models/forecasts/projection/period_simulator.rb (periods, metrics)
//
// Shared verbatim between the browser (importmap pin "forecast/preview_engine")
// and the node --test parity suite (test/javascript), so it must stay PURE:
// zero imports, no DOM, no clock. The ONLY Date usage is new Date(Date.UTC(...))
// for calendar arithmetic (daysInMonth/addDays), which is deterministic — no
// timezone, no Date.now().
//
// Dates are plain {y, m, d} objects (m is 1-12); ISO strings at the edges.

// --- Dates -----------------------------------------------------------------

// "YYYY-MM-DD..." -> {y, m, d}. Longer ISO strings (timestamps) contribute
// only their date part, mirroring Ruby Date.parse on packet values. Returns
// null for null/"" (Ruby parse_date) and throws on garbage.
export function parseDate(iso) {
  if (iso == null || iso === "") return null;
  const y = Number(iso.slice(0, 4));
  const m = Number(iso.slice(5, 7));
  const d = Number(iso.slice(8, 10));
  if (!Number.isInteger(y) || !Number.isInteger(m) || !Number.isInteger(d) || m < 1 || d < 1) {
    throw new Error(`Unparseable date ${JSON.stringify(iso)}`);
  }
  return { y, m, d };
}

export function toISO(date) {
  return `${String(date.y).padStart(4, "0")}-${String(date.m).padStart(2, "0")}-${String(date.d).padStart(2, "0")}`;
}

// Day 0 of the FOLLOWING month (Date.UTC months are 0-based, so index `m` is
// month m+1) is the last day of month m. Deterministic: UTC only, no clock.
export function daysInMonth(y, m) {
  return new Date(Date.UTC(y, m, 0)).getUTCDate();
}

// Ruby Date#>> mirror: advance n calendar months, clamping the day-of-month
// to the target month's last day (2026-01-31 >> 1 == 2026-02-28).
export function addMonths(date, n) {
  const total = date.y * 12 + (date.m - 1) + n;
  const y = Math.floor(total / 12);
  const m = (total % 12) + 1;
  return { y, m, d: Math.min(date.d, daysInMonth(y, m)) };
}

export function addDays(date, n) {
  const shifted = new Date(Date.UTC(date.y, date.m - 1, date.d + n));
  return { y: shifted.getUTCFullYear(), m: shifted.getUTCMonth() + 1, d: shifted.getUTCDate() };
}

export function compareDates(a, b) {
  return a.y - b.y || a.m - b.m || a.d - b.d;
}

export function periodKey(date) {
  return `${String(date.y).padStart(4, "0")}-${String(date.m).padStart(2, "0")}`;
}

function isLeapYear(y) {
  return (y % 4 === 0 && y % 100 !== 0) || y % 400 === 0;
}

// Ruby Expanders::Base#elapsed_years mirror: whole years elapsed since the
// window start's anniversary — `occ.year - start.year`, return 0 when <= 0,
// minus one when (occ.month, occ.day) falls before that year's anniversary
// (month, day). A Feb-29 anchor compares against Feb 28 in non-leap
// OCCURRENCE years, exactly like Ruby's Date.new fallback.
export function elapsedYears(start, occ) {
  const years = occ.y - start.y;
  if (years <= 0) return 0;

  const month = start.m;
  let day = start.d;
  if (day === 29 && month === 2 && !isLeapYear(occ.y)) day = 28;

  if (occ.m < month || (occ.m === month && occ.d < day)) return years - 1;
  return years;
}

// --- Occurrence walk ---------------------------------------------------------

// Ruby Expanders::Base#advance mirror: every step advances FROM THE ANCHOR
// (anchor >> index), never from the previous occurrence, so day-of-month is
// preserved with no drift — monthly from Jan 31 yields Jan 31, Feb 28, Mar 31.
function advance(anchor, frequency, index) {
  switch (frequency) {
    case "weekly":
      return addDays(anchor, 7 * index);
    case "biweekly":
      return addDays(anchor, 14 * index);
    case "monthly":
      return addMonths(anchor, index);
    case "quarterly":
      return addMonths(anchor, 3 * index);
    case "semiannual":
      return addMonths(anchor, 6 * index);
    case "annual":
    case "yearly":
      return addMonths(anchor, 12 * index);
    default:
      throw new Error(`Unsupported frequency ${JSON.stringify(frequency)}`);
  }
}

// Occurrence dates for one frequency over the inclusive [startOn, endOn]
// window (Ruby Expanders::Base#expand_occurrence_walk). `one_time` emits a
// single occurrence at the window start; an empty window emits none. Throws
// on an unknown frequency (Ruby InvalidExpansionError).
export function occurrenceDates(frequency, startOn, endOn) {
  const freq = String(frequency);
  const dates = [];
  let index = 0;
  let date = startOn;

  for (;;) {
    if (compareDates(date, endOn) > 0) break;
    dates.push(date);
    if (freq === "one_time") break;
    index += 1;
    date = advance(startOn, freq, index);
  }
  return dates;
}

// --- Window / period count ---------------------------------------------------

// Ruby Expanders::Base#occurrence_window mirror: clamp the assumption's
// [start, end] anchors into the horizon. Null anchors fall back to the
// horizon bounds; returns null when the clamped window is empty (end before
// start) so the caller emits no flows. horizon = {start: {y,m,d}, end: {y,m,d}}.
export function clampWindow(startOn, endOn, horizon) {
  let start = startOn || horizon.start;
  let end = endOn || horizon.end;

  if (compareDates(start, horizon.start) < 0) start = horizon.start;
  if (compareDates(end, horizon.end) > 0) end = horizon.end;

  return compareDates(end, start) < 0 ? null : [start, end];
}

// Ruby PeriodSimulator#month_count mirror: monthly windows INCLUSIVE of the
// month containing the horizon end — span months + 1, never below 1. A flow
// dated on the horizon-end boundary belongs to the period containing it, so
// counting only the span would drop the final month.
export function monthCount(horizon) {
  const span = (horizon.end.y - horizon.start.y) * 12 + (horizon.end.m - horizon.start.m);
  return Math.max(span + 1, 1);
}

// --- Money ---------------------------------------------------------------

// Round to cents. Math.round rounds half toward +Infinity, which equals
// Ruby BigDecimal's ROUND_HALF_UP for the POSITIVE amounts the current kinds
// produce; the Number.EPSILON nudge lifts binary representations sitting a
// hair below .5 (e.g. 1.005 stored as 1.00499999...) over the boundary, so
// decimal half-up is preserved.
export function round2(x) {
  return Math.round((x + Number.EPSILON) * 100) / 100;
}
