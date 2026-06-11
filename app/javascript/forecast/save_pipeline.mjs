// DOM-free, module-singleton save pipeline for the forecast workspace (spec
// §4.5 save discipline): at most ONE assumption save request in flight at a
// time. While one is in flight, later requests coalesce per key (the LATEST
// submit wins for a key; keys fire in FIFO order) and fire one-by-one as
// their predecessors settle. Pure ESM, zero imports, no DOM — exercised by
// the node --test suite with mocked timers; the editor controller and undo
// toast are its production callers (importmap pin "forecast/save_pipeline").

// If a submitter never reports back (crashed turbo lifecycle, dropped
// network), reopen the pipeline after this long so saves can never wedge
// shut behind a ghost request.
export const WATCHDOG_MS = 10_000;

let inFlight = false;
let watchdogTimer = null;
// Insertion-ordered Map: set() on an existing key REPLACES the submit but
// keeps the key's queue position — exactly "latest wins per key, FIFO across
// keys" with no extra bookkeeping.
const queued = new Map();

function clearWatchdog() {
  if (watchdogTimer !== null) {
    clearTimeout(watchdogTimer);
    watchdogTimer = null;
  }
}

function fire(submit) {
  inFlight = true;
  watchdogTimer = setTimeout(settled, WATCHDOG_MS);
  try {
    submit();
  } catch (error) {
    // A submit that throws synchronously will never reach its own settled()
    // call; settle on its behalf so the pipeline cannot wedge, then surface
    // the bug to the caller.
    settled();
    throw error;
  }
}

// Fires `submit` now when the pipeline is idle (returns true); otherwise
// coalesces it under `key` (returns false). Every fired submit MUST
// eventually be followed by settled() — the watchdog covers the pathological
// case where it is not.
export function requestSave(key, submit) {
  if (inFlight) {
    queued.set(key, submit);
    return false;
  }
  fire(submit);
  return true;
}

// Called by every submitter when its request finishes (success OR failure).
// Reopens the pipeline and fires the oldest queued save, if any. Idempotent
// when idle. Known accepted edge: a LATE real settle arriving after a
// watchdog force-settle (while the next save is already in flight) settles
// that next save early — worst case is two briefly-overlapping PATCHes,
// which the server's optimistic locking already arbitrates.
export function settled() {
  if (!inFlight) return;

  clearWatchdog();
  inFlight = false;

  const next = queued.entries().next();
  if (next.done) return;

  const [key, submit] = next.value;
  queued.delete(key);
  fire(submit);
}

export function hasQueued(key) {
  return queued.has(key);
}

export function isInFlight() {
  return inFlight;
}

// Test hook: returns the singleton to its pristine idle state.
export function reset() {
  clearWatchdog();
  inFlight = false;
  queued.clear();
}
