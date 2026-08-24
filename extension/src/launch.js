// Pure helper for the cold-launch wait. No `export` and no imports: worker.js is a
// CLASSIC service worker and pulls this in with importScripts — see worker.js's header for
// why it is not a module. Kept pure (clock and probe injected) so the 30 second bound can
// be tested against a fake clock instead of 30 real seconds — test/launch.test.js.
//
// Why this is not a fixed sleep, which is what it replaced (item 11, measured 2026-08-18):
// triggering `carabiner://launch` does not start the app. It makes Chrome show a tab-modal
// "Open Carabiner?" dialog, and the app starts only once a HUMAN clicks it. The old code
// waited a fixed 2500ms — sized against a measured 0.21s cold launch — and so gave up
// while the dialog was still on screen. The app came up; the grab still failed. The wait
// is gated on a person, so it has to watch for the app rather than guess at a duration.

/**
 * Polls `probe` until it reports the app is reachable, or `timeoutMs` elapses.
 *
 * @param {() => Promise<boolean>} probe  Truthy ⇒ the app is up. May reject: a fetch to a
 *   dead port REJECTS rather than resolving falsy, and that is the normal case here, so a
 *   rejection is treated as "not up yet" rather than allowed to escape.
 * @param {number} timeoutMs  Hard upper bound on the whole wait.
 * @param {number} intervalMs Pause between polls.
 * @param {(ms:number)=>Promise<void>} sleep
 * @param {() => number} now  Milliseconds, monotonic-ish. Real caller passes Date.now.
 * @param {number} [probeTimeoutMs] Bound on a SINGLE probe. Measured 2026-08-18: a probe
 *   that never settles parks the loop forever and the overall deadline is never reached,
 *   because it is only evaluated between probes. A bound a hung probe can disable is not a
 *   bound (gotcha #33). Defaults to Infinity so callers that cannot hang keep the simple
 *   path; the worker passes a real value because `fetch` demonstrably can hang here.
 * @returns {Promise<boolean>} true if the app answered, false if the bound was reached.
 */
async function waitForApp({ probe, timeoutMs, intervalMs, sleep, now, probeTimeoutMs = Infinity }) {
  const deadline = now() + timeoutMs;
  for (;;) {
    // A rejected probe is the expected shape of "connection refused", so it counts as
    // "not up yet" rather than escaping.
    const attempt = Promise.resolve().then(probe).then(Boolean, () => false);
    const settled = Number.isFinite(probeTimeoutMs)
      ? await Promise.race([attempt, sleep(probeTimeoutMs).then(() => false)])
      : await attempt;
    if (settled) return true;
    // Checked AFTER the probe so a probe that is itself slow cannot overrun the bound, and
    // BEFORE the sleep so we never sleep past the deadline just to re-check and give up.
    if (now() >= deadline) return false;
    await sleep(intervalMs);
  }
}
