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

// --- Packet normalization --------------------------------------------------

// Ruby PeriodSimulator::UNBOUNDED_RUNWAY_DAYS mirror: positive cash with zero
// burn never runs out, so a large documented integer stands in for infinity.
export const UNBOUNDED_RUNWAY_DAYS = 99999;

function normalizeAssumption(a) {
  // Packet-lite assumptions carry no status: the island only emits
  // already-enabled (active/draft) cards, so missing status means simulable.
  return { id: a.id, kind: a.kind, status: a.status == null ? "active" : String(a.status), params: a.params || {} };
}

// Accepts EITHER the full Ruby engine packet ({plan:{...}, assumptions,
// source_snapshot}) OR the island packet-lite ({horizon, currency, opening,
// assumptions}) and returns the engine's canonical shape:
//   {horizon: {start, end}, currency, opening: {lc, db, pv}, assumptions}.
export function normalizePacket(packet) {
  if (packet == null) throw new Error("packet is required");

  if (packet.plan) {
    const horizon = packet.plan.horizon || {};
    const opening = (packet.source_snapshot && packet.source_snapshot.opening_balances) || {};
    return {
      horizon: { start: parseDate(horizon.starts_on), end: parseDate(horizon.ends_on) },
      currency: packet.plan.reporting_currency,
      opening: {
        lc: Number(opening.liquid_cash || 0),
        db: Number(opening.debt_balance || 0),
        pv: Number(opening.portfolio_value || 0),
      },
      assumptions: (packet.assumptions || []).map(normalizeAssumption),
    };
  }

  const horizon = packet.horizon || {};
  const opening = packet.opening || {};
  return {
    horizon: { start: parseDate(horizon.starts_on), end: parseDate(horizon.ends_on) },
    currency: packet.currency,
    opening: {
      lc: Number(opening.lc || 0),
      db: Number(opening.db || 0),
      pv: Number(opening.pv || 0),
    },
    assumptions: (packet.assumptions || []).map(normalizeAssumption),
  };
}

// --- Assumption expansion ----------------------------------------------------

// Anchors in a JS-visible packet are ALWAYS fixed dates: the island
// pre-resolves milestone references to {type:"date", on:} (WorkspaceIsland
// #packet_assumption) and marks unresolvable cards pv:false. Hitting a
// milestone anchor here means that contract broke — fail loudly, never guess.
function resolveAnchor(anchor) {
  if (anchor == null) return null;
  const type = String(anchor.type == null ? "" : anchor.type);
  if (type === "date") return parseDate(anchor.on || anchor.date);
  if (type === "milestone") {
    throw new Error("Unresolved milestone anchor; the island must pre-resolve milestone anchors to dates");
  }
  throw new Error(`Unknown anchor type ${JSON.stringify(type)}`);
}

// Compounding annual multiplier, anchored at the (clamped) window start —
// Ruby Expanders::Base#annual_compounding_factor over #elapsed_years.
function policyFactor(policy, windowStart, occ) {
  return policy?.type === "annual_percentage"
    ? (1 + Number(policy.rate || 0)) ** elapsedYears(windowStart, occ)
    : 1;
}

// Expands one assumption over the horizon into Map(periodKey -> {income,
// spending}) — the JS twin of Expanders::Salary / Expanders::LivingExpense.
// Unknown kinds return an empty Map (they never preview; the registry
// preview flag and the island's pv flag gate them upstream as well).
// horizon = {start: {y,m,d}, end: {y,m,d}}.
export function expandAssumption(assumption, horizon) {
  const params = assumption.params || {};
  const flows = new Map();

  const window = clampWindow(
    resolveAnchor(params.start_anchor),
    resolveAnchor(params.end_anchor),
    horizon,
  );
  if (window == null) return flows;
  const [startOn, endOn] = window;

  const base = Number(params.amount || 0);
  const frequency = params.frequency == null ? "monthly" : String(params.frequency);

  let category;
  let policy;
  let multiplier = 1;
  if (assumption.kind === "salary") {
    category = "income";
    policy = params.growth_policy;
    // Ruby Expanders::Salary: cash impact is the NET amount. Gross salaries
    // multiply by net_ratio; absent/blank net_ratio defaults to 1 so a
    // take-home cut is never silently fabricated.
    if (String(params.gross_or_net || "net") === "gross") {
      multiplier = params.net_ratio == null || params.net_ratio === "" ? 1 : Number(params.net_ratio);
    }
  } else if (assumption.kind === "living_expense") {
    category = "spending";
    policy = params.inflation_policy;
  } else {
    return flows;
  }

  for (const occ of occurrenceDates(frequency, startOn, endOn)) {
    // Ruby format_money rounds EVERY occurrence to cents BEFORE the
    // simulator sums them — round here, then sum, never the other way.
    const amount = round2(base * policyFactor(policy, startOn, occ) * multiplier);
    const key = periodKey(occ);
    // A 0-amount occurrence still creates the entry: occupancy mirrors Ruby
    // trace rows, which exist regardless of amount.
    const entry = flows.get(key) || { income: 0, spending: 0 };
    entry[category] += amount;
    flows.set(key, entry);
  }
  return flows;
}

// --- Projection ------------------------------------------------------------

// Ruby PeriodSimulator#runway_days mirror: non-positive cash -> 0 days;
// positive cash with no burn -> the unbounded sentinel; else floor(cash /
// average daily spend). Uses the UNROUNDED running values, like Ruby.
function runwayDays(liquidCash, spending, daysInPeriod) {
  if (liquidCash <= 0) return 0;
  if (spending <= 0) return UNBOUNDED_RUNWAY_DAYS;
  return Math.floor(liquidCash / (spending / daysInPeriod));
}

// Full-packet projection — the JS twin of PeriodSimulator#simulate +
// Metrics#to_h, with FULL metric names so parity fixtures compare directly.
// Returns [{key, starts_on, metrics: {net_worth, liquid_cash, income,
// spending, debt_balance, portfolio_value, runway_days},
// active_assumption_ids}].
export function computeProjection(packet) {
  const { horizon, currency, opening, assumptions } = normalizePacket(packet);

  // PacketBuilder ENABLED_STATUSES mirror (active/draft), plus a currency
  // guard: the JS engine does no FX, so a foreign-currency card is skipped
  // entirely (its island card ships pv:false for the same reason). A nil
  // params currency falls back to the reporting currency, like Ruby's
  // `params[:currency] || context[:reporting_currency]`.
  const simulable = assumptions.filter(
    (a) =>
      (a.status === "active" || a.status === "draft") &&
      (a.params.currency == null || String(a.params.currency) === currency),
  );

  const flowsById = simulable.map((a) => [a.id, expandAssumption(a, horizon)]);

  const count = monthCount(horizon);
  const periods = [];
  let lc = opening.lc;
  const db = opening.db; // static in this slice (no debt/portfolio flow kinds yet)
  const pv = opening.pv;

  for (let i = 0; i < count; i += 1) {
    const monthStart = addMonths(horizon.start, i);
    const key = periodKey(monthStart);
    // The walk may land mid-month (mid-month horizon start), but the period
    // row reports the BEGINNING of the month — Ruby period_windows
    // (starts_on = month_start.beginning_of_month).
    const startsOn = toISO({ y: monthStart.y, m: monthStart.m, d: 1 });
    const days = daysInMonth(monthStart.y, monthStart.m);

    let income = 0;
    let spending = 0;
    const activeIds = [];
    for (const [id, flows] of flowsById) {
      const entry = flows.get(key);
      if (!entry) continue;
      income += entry.income;
      spending += entry.spending;
      activeIds.push(id); // 0-amount entries still count: activity == trace rows
    }

    lc += income - spending; // Ruby apply_period_totals
    const netWorth = lc + pv - db; // Ruby household_net_worth

    periods.push({
      key,
      starts_on: startsOn,
      metrics: {
        net_worth: round2(netWorth),
        liquid_cash: round2(lc),
        income: round2(income),
        spending: round2(spending),
        debt_balance: round2(db),
        portfolio_value: round2(pv),
        // Runway floors the UNROUNDED running values (Ruby rounds only in
        // Metrics#to_h, after runway is computed).
        runway_days: runwayDays(lc, spending, days),
      },
      // Default Array#sort is lexicographic — exactly Ruby's sort_by(&:to_s).
      active_assumption_ids: activeIds.sort(),
    });
  }
  return periods;
}

// --- Delta preview -----------------------------------------------------------

function adjustedActivity(aa, baseOccupied, overOccupied, ordinal) {
  if (baseOccupied === overOccupied) return aa;
  if (overOccupied) {
    // aa entries are numeric ordinals into the island's assumptions array.
    return aa.includes(ordinal) ? aa : [...aa, ordinal].sort((a, b) => a - b);
  }
  return aa.filter((entry) => entry !== ordinal);
}

// Delta-path preview for ONE edited assumption — the chart's per-keystroke
// path. Instead of re-simulating the whole packet, expand the edited card
// twice (baseline params vs override) and shift the server-computed island
// periods by the cumulative cash delta. This is EXACT, not approximate:
// every flow the JS cannot model is identical on both sides of the
// difference and cancels out.
//
// LINEARITY CAVEAT: valid while cash income/spending are the only flow
// effects (current engine apply_period_totals: liquid_cash += income -
// spending); phase-6 order-sensitive kinds must NOT ride this path (they're
// `preview: false`).
//
// islandPeriods are the chart's island rows ({k, s, m: {nw,lc,inc,sp,db,pv,
// rd}, aa: [ordinals]}; m values may be decimal strings — Number() them).
// `ordinal` is the edited card's index in the island assumptions array.
// Returns island-shaped periods, or null when the assumption isn't in the
// packet (chart falls back to island data).
export function previewPeriods(packet, islandPeriods, assumptionId, overrideParams, ordinal) {
  const { horizon, assumptions } = normalizePacket(packet);
  const assumption = assumptions.find((a) => a.id === assumptionId);
  if (!assumption) return null;

  const baseFlows = expandAssumption(assumption, horizon);
  const overFlows = expandAssumption(
    { ...assumption, params: { ...assumption.params, ...overrideParams } },
    horizon,
  );

  let cum = 0;
  return islandPeriods.map((period) => {
    const base = baseFlows.get(period.k);
    const over = overFlows.get(period.k);
    const incDelta = (over ? over.income : 0) - (base ? base.income : 0);
    const spDelta = (over ? over.spending : 0) - (base ? base.spending : 0);
    cum += incDelta - spDelta;

    // Untouched periods come back BY IDENTITY: re-rounding them could
    // flicker pixels the user never edited. Occupancy must ALSO be
    // unchanged: a 0-amount occurrence appearing or disappearing changes
    // `aa` with zero cash delta (occupancy mirrors Ruby trace rows, which
    // exist regardless of amount — see expandAssumption), so that edge
    // flows into the rebuild below, whose adjustedActivity call handles it;
    // the rebuilt metrics are numerically identical since all deltas are 0.
    if (incDelta === 0 && spDelta === 0 && cum === 0 && Boolean(base) === Boolean(over)) {
      return period;
    }

    // Runway floors the pre-rounding values, matching computeProjection's
    // use of the unrounded running balance.
    const lcPrime = Number(period.m.lc) + cum;
    const spPrime = Number(period.m.sp) + spDelta;
    const [y, m] = period.k.split("-").map(Number);

    return {
      k: period.k,
      s: period.s,
      m: {
        nw: round2(Number(period.m.nw) + cum),
        lc: round2(lcPrime),
        inc: round2(Number(period.m.inc) + incDelta),
        sp: round2(spPrime),
        db: period.m.db, // static in this slice: pass through untouched
        pv: period.m.pv,
        rd: runwayDays(lcPrime, spPrime, daysInMonth(y, m)),
      },
      aa: adjustedActivity(period.aa, Boolean(base), Boolean(over), ordinal),
    };
  });
}
