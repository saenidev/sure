import { beforeEach, test } from "node:test";
import assert from "node:assert/strict";
import {
  WATCHDOG_MS,
  hasQueued,
  isInFlight,
  requestSave,
  reset,
  settled,
} from "../../app/javascript/forecast/save_pipeline.mjs";

// The pipeline is a module singleton: return it to pristine idle between tests.
beforeEach(() => reset());

test("fires immediately when idle", () => {
  let calls = 0;
  const fired = requestSave("card-1", () => {
    calls += 1;
  });

  assert.equal(fired, true);
  assert.equal(calls, 1);
  assert.equal(isInFlight(), true);
  assert.equal(hasQueued("card-1"), false);
});

test("holds later saves until the in-flight one settles", () => {
  const log = [];
  requestSave("card-1", () => log.push("a"));
  const fired = requestSave("card-2", () => log.push("b"));

  assert.equal(fired, false);
  assert.deepEqual(log, ["a"]);
  assert.equal(hasQueued("card-2"), true);

  settled();
  assert.deepEqual(log, ["a", "b"]);
  assert.equal(hasQueued("card-2"), false);
  assert.equal(isInFlight(), true); // b is now the in-flight save
});

test("coalesces per key, keeping the LATEST submit", () => {
  const log = [];
  requestSave("card-1", () => log.push("first"));
  requestSave("card-2", () => log.push("stale"));
  requestSave("card-2", () => log.push("fresh"));

  settled();
  assert.deepEqual(log, ["first", "fresh"]);
});

test("fires queued saves FIFO across keys; coalescing keeps queue position", () => {
  const log = [];
  requestSave("card-1", () => log.push("a"));
  requestSave("card-2", () => log.push("b1"));
  requestSave("card-3", () => log.push("c"));
  requestSave("card-2", () => log.push("b2")); // replaces b1, keeps card-2's slot

  settled(); // -> card-2 fires b2
  settled(); // -> card-3 fires c
  settled(); // queue drained
  assert.deepEqual(log, ["a", "b2", "c"]);
  assert.equal(isInFlight(), false);
});

test("watchdog reopens the pipeline when a settle never arrives", (t) => {
  t.mock.timers.enable({ apis: ["setTimeout"] });
  const log = [];
  requestSave("card-1", () => log.push("a")); // never settles (lost turbo lifecycle)
  requestSave("card-2", () => log.push("b"));
  assert.deepEqual(log, ["a"]);

  t.mock.timers.tick(WATCHDOG_MS);
  assert.deepEqual(log, ["a", "b"]); // the wedged save was force-settled, b fired
});

test("a synchronously-throwing submit settles the pipeline and rethrows", () => {
  assert.throws(
    () =>
      requestSave("card-1", () => {
        throw new Error("boom");
      }),
    /boom/,
  );
  assert.equal(isInFlight(), false);

  // The pipeline is usable again afterwards.
  let calls = 0;
  assert.equal(
    requestSave("card-2", () => {
      calls += 1;
    }),
    true,
  );
  assert.equal(calls, 1);
});

test("settled when idle is a no-op", () => {
  settled();
  assert.equal(isInFlight(), false);
});
