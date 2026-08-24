import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";

// launch.js — the pure "is the app up yet?" wait, extracted so it can be driven with a
// fake clock instead of a real 30 second one. Same `new Function` extraction pattern as
// ndjson.test.js and worker.test.js, for the identical reason: launch.js is loaded by a
// CLASSIC service worker via importScripts and therefore has no `export`.
//
// This exists because of a measured field failure (item 11, 2026-08-18). The old code
// waited a FIXED 2500ms after triggering `carabiner://launch` and then retried once. That
// number was budgeted against a measured 0.21s cold launch — but the launch is gated on a
// human answering Chrome's "Open Carabiner?" dialog, so the real wait is human reaction
// time. Measured live: the app came up fine and the grab still failed with a red X,
// because 2500ms expired while the dialog was still on screen.
//
// Gotcha #34 applies: these tests pin the helper only. worker.test.js pins the WIRING —
// deleting the call here would leave every test below green.

const srcDir = path.join(path.dirname(fileURLToPath(import.meta.url)), "..", "src");
const { waitForApp } = new Function(
  `${readFileSync(path.join(srcDir, "launch.js"), "utf8")}\nreturn { waitForApp };`
)();

/**
 * A fake clock: `sleep` advances virtual time instantly, so a 30s bound costs no wall time.
 *
 * `sleep` deliberately resolves on a MACROTASK (setTimeout 0) rather than a microtask. A
 * real sleep is always later than an already-answered fetch, and the probe-timeout race
 * depends on that ordering — with a microtask sleep the race is decided by hop-counting
 * and a probe that answers instantly can lose to its own timeout, which no real clock
 * would ever do.
 */
function fakeClock() {
  let t = 0;
  const slept = [];
  return {
    now: () => t,
    sleep: (ms) => new Promise((r) => setTimeout(() => { slept.push(ms); t += ms; r(); }, 0)),
    slept,
    advanceTo: (v) => { t = v; },
  };
}

test("an app that is already up returns immediately, without sleeping once", async () => {
  const clock = fakeClock();
  const up = await waitForApp({
    probe: async () => true,
    timeoutMs: 30000, intervalMs: 250, sleep: clock.sleep, now: clock.now,
  });
  assert.equal(up, true);
  assert.deepEqual(clock.slept, [], "a reachable app must not cost even one poll interval");
});

test("it keeps waiting well past the old fixed 2500ms budget — the regression that shipped", async () => {
  // The exact field failure: the human takes ~6s to read and answer the dialog. The old
  // fixed 2500ms wait gave up at 2.5s and reported a dead port as a failed grab.
  const clock = fakeClock();
  const APP_UP_AT = 6000;
  const up = await waitForApp({
    probe: async () => clock.now() >= APP_UP_AT,
    timeoutMs: 30000, intervalMs: 250, sleep: clock.sleep, now: clock.now,
  });
  assert.equal(up, true, "a 6s human must not be read as 'Carabiner failed to start'");
  assert.ok(clock.now() >= APP_UP_AT, "it must actually have waited, not returned early");
  assert.ok(clock.now() < 30000, "and it must stop as soon as the app answers");
});

test("a probe that throws counts as 'not up yet', not as a crash", async () => {
  // fetch() to a dead port REJECTS — it does not resolve with ok:false. If waitForApp let
  // that escape, the very case it exists for (the app not running) would blow up the wait.
  const clock = fakeClock();
  let calls = 0;
  const up = await waitForApp({
    probe: async () => { calls += 1; if (calls < 4) throw new Error("connection refused"); return true; },
    timeoutMs: 30000, intervalMs: 250, sleep: clock.sleep, now: clock.now,
  });
  assert.equal(up, true);
  assert.equal(calls, 4);
});

test("an app that never comes up returns false at the bound, rather than polling forever", async () => {
  const clock = fakeClock();
  let calls = 0;
  const up = await waitForApp({
    probe: async () => { calls += 1; return false; },
    timeoutMs: 30000, intervalMs: 250, sleep: clock.sleep, now: clock.now,
  });
  assert.equal(up, false, "the bound must be a real bound — gotcha #33");
  assert.ok(clock.now() >= 30000, "it must not give up early");
  assert.ok(calls > 1 && calls <= 130, `expected a bounded number of polls, got ${calls}`);
});

test("a probe that NEVER settles is bounded and keeps polling — the hang that shipped", async () => {
  // Measured 2026-08-18: the app was up 2s after the launch tab appeared, yet the wait
  // never returned and the 120s bound never fired. `fetch` to the freshly bound port hung
  // instead of resolving or rejecting, and the deadline is only consulted BETWEEN probes —
  // so one hung probe disabled the bound entirely and the grab was lost in silence.
  const clock = fakeClock();
  let calls = 0;
  const up = await waitForApp({
    probe: () => { calls += 1; return new Promise(() => {}); }, // never settles, ever
    timeoutMs: 30000, intervalMs: 250, probeTimeoutMs: 2000,
    sleep: clock.sleep, now: clock.now,
  });
  assert.equal(up, false, "a hung probe must not park the loop forever");
  assert.ok(calls > 1, `a hung probe must be abandoned and retried, not awaited forever (${calls} calls)`);
});

test("a probe that hangs once, then answers, still succeeds", async () => {
  // The bound on a single probe must not turn a transient hang into a permanent verdict.
  const clock = fakeClock();
  let calls = 0;
  const up = await waitForApp({
    probe: () => { calls += 1; return calls === 1 ? new Promise(() => {}) : Promise.resolve(true); },
    timeoutMs: 30000, intervalMs: 250, probeTimeoutMs: 2000,
    sleep: clock.sleep, now: clock.now,
  });
  assert.equal(up, true);
  assert.equal(calls, 2);
});

test("the deadline is checked against elapsed time, not against a poll count", async () => {
  // A probe that itself takes a long time (a slow/hanging fetch) must still be bounded:
  // counting polls would let 30 slow probes run for minutes.
  const clock = fakeClock();
  let calls = 0;
  const up = await waitForApp({
    probe: async () => { calls += 1; clock.advanceTo(clock.now() + 11000); return false; },
    timeoutMs: 30000, intervalMs: 250, sleep: clock.sleep, now: clock.now,
  });
  assert.equal(up, false);
  assert.ok(calls <= 4, `a probe burning 11s each must be bounded by the clock, got ${calls} calls`);
});
