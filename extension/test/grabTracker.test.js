import { test } from "node:test";
import assert from "node:assert/strict";
import { createGrabTracker } from "../src/grabTracker.js";

// A fake clock so watchdog timing is driven by hand rather than real wall-clock delays.
// `lastHandle` lets a test fire "whatever the tracker most recently armed" without the
// tracker needing to expose its internal timer handles.
function makeFakeClock() {
  let counter = 0;
  const pending = new Map();
  let lastHandle;
  return {
    setTimeoutFn: (fn) => {
      const id = ++counter;
      pending.set(id, fn);
      lastHandle = id;
      return id;
    },
    clearTimeoutFn: (id) => {
      pending.delete(id);
    },
    fire: (id) => {
      const fn = pending.get(id);
      if (!fn) throw new Error(`timer ${id} is not pending (already cleared or already fired)`);
      pending.delete(id);
      fn();
    },
    get lastHandle() {
      return lastHandle;
    },
    pendingCount: () => pending.size,
  };
}

function makeOwner() {
  const calls = { setRing: [], settle: [] };
  return {
    calls,
    setRing: (fraction) => calls.setRing.push(fraction),
    settle: (outcome) => calls.settle.push(outcome),
  };
}

function makeTracker(clock, watchdogMs = 1000) {
  return createGrabTracker({ watchdogMs, setTimeoutFn: clock.setTimeoutFn, clearTimeoutFn: clock.clearTimeoutFn });
}

test("progress routes to setRing on the matching owner", () => {
  const clock = makeFakeClock();
  const tracker = makeTracker(clock);
  const owner = makeOwner();
  tracker.start("a", owner);
  tracker.receive({ id: "a", type: "progress", stage: "download", pct: 50 });
  assert.deepEqual(owner.calls.setRing, [0.5]);
});

test("done routes to settle and stops tracking the grab", () => {
  const clock = makeFakeClock();
  const tracker = makeTracker(clock);
  const owner = makeOwner();
  tracker.start("a", owner);
  tracker.receive({ id: "a", type: "done", result: "ok" });
  assert.deepEqual(owner.calls.settle, ["ok"]);
  assert.equal(tracker.has("a"), false);
});

test("two simultaneous grabs never cross-wire (fix round 1, Finding 2 regression)", () => {
  const clock = makeFakeClock();
  const tracker = makeTracker(clock);
  const ownerA = makeOwner();
  const ownerB = makeOwner();
  tracker.start("a", ownerA);
  tracker.start("b", ownerB);
  tracker.receive({ id: "b", type: "done", result: "error", message: "A grab is already running" });
  tracker.receive({ id: "a", type: "done", result: "ok" });
  assert.deepEqual(ownerA.calls.settle, ["ok"]);
  assert.deepEqual(ownerB.calls.settle, ["error"]);
});

test("fix round 2, Finding 1(a): the watchdog does not delete the grab — it settles amber and keeps listening", () => {
  const clock = makeFakeClock();
  const tracker = makeTracker(clock);
  const owner = makeOwner();
  tracker.start("a", owner);
  clock.fire(clock.lastHandle); // simulate watchdogMs of silence
  assert.deepEqual(owner.calls.settle, ["interrupted"]);
  assert.equal(tracker.has("a"), true, "the grab must still be tracked after the watchdog fires");
});

test("fix round 2, Finding 1(a): a late `done` after the watchdog fired still corrects the button — this is the regression this round exists to prevent", () => {
  const clock = makeFakeClock();
  const tracker = makeTracker(clock);
  const owner = makeOwner();
  tracker.start("a", owner);
  clock.fire(clock.lastHandle); // watchdog fires -> amber "interrupted"
  assert.deepEqual(owner.calls.settle, ["interrupted"]);

  const handled = tracker.receive({ id: "a", type: "done", result: "ok" });
  assert.equal(handled, true, "a late done for an amber grab must still be handled, not silently dropped");
  assert.deepEqual(owner.calls.settle, ["interrupted", "ok"]);
  assert.equal(tracker.has("a"), false);
});

test("fix round 2, Finding 1(a): a late `progress` after the watchdog fired re-adopts the button back to its ring", () => {
  const clock = makeFakeClock();
  const tracker = makeTracker(clock);
  const owner = makeOwner();
  tracker.start("a", owner);
  clock.fire(clock.lastHandle); // watchdog fires -> amber "interrupted"

  const handled = tracker.receive({ id: "a", type: "progress", stage: "download", pct: 75 });
  assert.equal(handled, true);
  assert.deepEqual(owner.calls.setRing, [0.75]);
  assert.equal(tracker.has("a"), true);
});

test("fix round 2, Finding 1(b): the watchdog is suspended (not just un-rearmed) while the last message was `prompt`, and re-arms on the next real message", () => {
  const clock = makeFakeClock();
  const tracker = makeTracker(clock);
  const owner = makeOwner();
  tracker.start("a", owner);
  const initialHandle = clock.lastHandle;

  tracker.receive({ id: "a", type: "progress", stage: "prompt" });
  // Suspended, not merely left un-rearmed: the original timer must actually be cleared,
  // not just superseded by a later one.
  assert.throws(() => clock.fire(initialHandle));
  assert.equal(clock.pendingCount(), 0);
  // prompt never advances the ring either (ring.js's own rule).
  assert.deepEqual(owner.calls.setRing, []);

  tracker.receive({ id: "a", type: "progress", stage: "download", pct: 10 });
  assert.equal(clock.pendingCount(), 1, "a real message after prompt must re-arm the watchdog");
  clock.fire(clock.lastHandle);
  assert.deepEqual(owner.calls.settle, ["interrupted"]);
});

test("abort (a click that never reached a live worker) really does end tracking — no re-adoption", () => {
  const clock = makeFakeClock();
  const tracker = makeTracker(clock);
  const owner = makeOwner();
  tracker.start("a", owner);
  tracker.abort("a");
  assert.equal(tracker.has("a"), false);

  const handled = tracker.receive({ id: "a", type: "done", result: "ok" });
  assert.equal(handled, false, "an aborted grab must not be resurrected by a stray late message");
  assert.deepEqual(owner.calls.settle, []);
});

test("a message with no id, or for an unknown id, is ignored rather than throwing", () => {
  const clock = makeFakeClock();
  const tracker = makeTracker(clock);
  assert.equal(tracker.receive(null), false);
  assert.equal(tracker.receive(undefined), false);
  assert.equal(tracker.receive({ type: "progress" }), false);
  assert.equal(tracker.receive({ id: "nobody-started-this", type: "done", result: "ok" }), false);
});

test("cancelled and error outcomes are routed through settle untouched — the button decides how to render them", () => {
  const clock = makeFakeClock();
  const tracker = makeTracker(clock);
  const owner = makeOwner();
  tracker.start("a", owner);
  tracker.receive({ id: "a", type: "done", result: "cancelled" });
  assert.deepEqual(owner.calls.settle, ["cancelled"]);
});
