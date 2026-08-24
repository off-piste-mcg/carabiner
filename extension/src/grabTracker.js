import { ringFractionForProgress, outcomeFor } from "./ring.js";

// The whole per-grab lifecycle: routing worker messages to the button that owns each
// grab (fix round 1, Finding 2 — a single "most recently clicked" pointer cross-wired
// two buttons), and the "we've lost track of this grab" watchdog (fix round 1, Finding
// 6; corrected in fix round 2, Finding 1 — see below). Extracted into its own module,
// independent of chrome.* / the DOM / real timers, specifically so the re-adoption
// behaviour below — the exact thing fix round 2 exists to fix — can be driven and
// asserted directly instead of trusted by inspection.
//
// An `owner` is whatever the caller wants; this module only ever calls two methods on
// it: `setRing(fraction)` while progress is live, and `settle(outcome)` — one of
// "ok" | "cancelled" | "error" | "interrupted" — when the grab stops (or temporarily
// stops) being tracked. content.js supplies real button controls; tests supply plain
// mock functions and assert on the calls made to them.
//
// FIX ROUND 2, FINDING 1: the watchdog firing used to delete the grab from tracking,
// which turned "interrupted" into a VERDICT instead of a status — a late `done` for a
// grab that was simply slow (a multi-minute encode with no intervening progress line, a
// carousel dialog a human is still reading) was silently dropped, leaving the button
// amber forever even though the grab had actually succeeded. Traced by the reviewer to
// three ordinary, unremarkable paths in the engine this ships against: a multi-minute
// video's silent libx264 encode (gotcha #21), gallery-dl emitting no progress at all
// after its one `download` marker, and an arbitrarily long human read of the carousel
// dialog. The fix has two halves, both here:
//   (a) firing the watchdog no longer removes the grab from `grabs` — it only calls
//       `owner.settle("interrupted")`. A later `progress` message still finds its owner
//       and calls `setRing` again (visually returning the button to its ring); a later
//       `done` still finds its owner and settles it for real, only THEN removing it.
//       Amber means "no news", never a verdict.
//   (b) the watchdog is suspended entirely (cleared, not just left un-rearmed) while the
//       most recent message for a grab was `{stage:"prompt"}` — a human reading the
//       native carousel dialog is not a stalled grab, and the app's own multi-hour
//       backstop (GrabServer.pausedTimeout) already bounds that wait server-side; this
//       mirrors the same reasoning client-side. It re-arms on the next non-prompt message.
export function createGrabTracker({ watchdogMs, setTimeoutFn = setTimeout, clearTimeoutFn = clearTimeout } = {}) {
  const grabs = new Map();     // id -> owner
  const watchdogs = new Map(); // id -> timer handle

  function clearWatchdog(id) {
    const t = watchdogs.get(id);
    if (t !== undefined) {
      clearTimeoutFn(t);
      watchdogs.delete(id);
    }
  }

  function armWatchdog(id) {
    clearWatchdog(id);
    watchdogs.set(id, setTimeoutFn(() => {
      watchdogs.delete(id);
      const owner = grabs.get(id);
      if (!owner) return; // already settled through the normal `done` path
      owner.settle("interrupted");
      // Deliberately NOT grabs.delete(id) here — see the module header, Finding 1(a).
    }, watchdogMs));
  }

  /** Begin tracking a newly-clicked grab. */
  function start(id, owner) {
    grabs.set(id, owner);
    armWatchdog(id);
  }

  /**
   * The click never reached a live worker at all (fix round 1, Finding 3: a dead/
   * unregistered service worker, or fix round 2's synchronous-throw case). Unlike a
   * fired watchdog, there is no stream to re-adopt later — this really does end it.
   */
  function abort(id) {
    clearWatchdog(id);
    grabs.delete(id);
  }

  /**
   * Route one worker message to the owner it belongs to.
   * @returns {boolean} true if some owner handled it, false if the message's id is
   *   untracked (never ours, or already settled for real via a previous `done`).
   */
  function receive(msg) {
    if (msg == null || msg.id == null) return false;
    const owner = grabs.get(msg.id);
    if (!owner) return false;
    if (msg.type === "progress") {
      if (msg.stage === "prompt") {
        // Finding 1(b): suspend, don't rearm — see module header.
        clearWatchdog(msg.id);
      } else {
        armWatchdog(msg.id); // any other real message resets the "we lost track" clock
      }
      const fraction = ringFractionForProgress(msg);
      if (fraction !== null) owner.setRing(fraction);
      return true;
    }
    if (msg.type === "done") {
      clearWatchdog(msg.id);
      grabs.delete(msg.id);
      owner.settle(outcomeFor(msg));
      return true;
    }
    return false;
  }

  /** Test/inspection helper: is this id still tracked (whether live or amber)? */
  function has(id) {
    return grabs.has(id);
  }

  return { start, abort, receive, has };
}
