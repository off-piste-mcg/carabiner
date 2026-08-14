// Pure mapping from a progress/done event (the wire shape written by
// app/Carabiner/Server/GrabEvent.swift: {"stage":...}, {"stage":"download","pct":42.5},
// {"stage":"item","index":2,"total":5}, {"result":"ok"|"error"|"cancelled",...}) to how
// the in-page button's ring should react.
//
// Extracted into its own module — rather than left inline in content.js's message
// listener — so the one rule that matters most can be unit-tested without a DOM: the
// ring means "downloading", so `probe`, `prompt` ("still thinking" and "waiting for you")
// and `save` (the completion flourish, not download feedback — it's the FIRST marker on
// some paths, see gotcha #23) must NOT advance it. The app's own menu-bar ring follows
// the identical rule for the identical reason — see ProgressEvent.swift's
// `beginsActivity`, which this module's `switch` is meant to match case-for-case. Final
// review, Finding 4: `save` used to be grouped with `convert` here and jump the ring to
// 100%, contradicting `beginsActivity` while this comment claimed the two were mirrored —
// keep them actually in sync, not just claimed to be, if either classification changes.
//
// Loaded via grabTracker.js's static `import` (fix round 2: content.js no longer imports
// this directly — grabTracker.js now owns the whole per-grab routing/watchdog lifecycle
// and calls this internally), which is itself reached via a dynamic import() of a
// web-accessible-resource URL from content.js, a classic content script that stays in the
// isolated world — see content.js's own header comment for why a page-context
// `type="module"` <script> tag, this project's first draft, was wrong. That dynamic
// import is unaffected by the background-worker module-loading constraint documented in
// worker.js and ndjson.js, so, unlike ndjson.js, this file needs no importScripts
// workaround and can use normal export.

/**
 * @param {{stage?: string, pct?: number, index?: number, total?: number}} event
 * @returns {number|null} a 0..1 fraction to set the ring to, or null if the ring must not move.
 */
export function ringFractionForProgress(event) {
  if (!event || typeof event.stage !== "string") return null;
  switch (event.stage) {
    case "download":
      // `pct` may be absent (GrabEvent.swift only includes it when known) — no fraction
      // to show yet, so leave the ring exactly where it is rather than guessing.
      return typeof event.pct === "number" ? clamp01(event.pct / 100) : null;
    case "item": {
      const total = Math.max(Number(event.total) || 0, 1);
      const index = typeof event.index === "number" ? event.index : 0;
      return clamp01(index / total);
    }
    case "convert":
      return 1;
    // `save` does NOT advance the ring — corrected, final review, Finding 4. This used to
    // be grouped with `convert` above and jump straight to 1, which directly contradicted
    // ProgressEvent.swift's `beginsActivity` (`.probe, .prompt, .save` are explicitly the
    // NOT-activity cases) despite this file's own header claiming the two mirror each
    // other. `convert` already leaves the ring at 1 by the time `save` arrives on any path
    // that reports `convert` at all; on a gallery-dl-only grab (no `convert` stage — see
    // gotcha #23) the ring simply stays wherever the last `item` left it until the
    // terminal `done` event repaints it as a tick, which is the actual completion signal
    // the user sees. Keep this case merged with `probe`/`prompt` below, not with
    // `convert` above, so the two files' classification of "is this activity" is
    // trivially diffable against each other again.
    case "probe":
    case "prompt":
    case "save":
    default:
      return null;
  }
}

/**
 * @param {{result?: string}} event the terminal line from the app.
 * @returns {"ok"|"cancelled"|"error"}
 */
export function outcomeFor(event) {
  if (event?.result === "ok") return "ok";
  if (event?.result === "cancelled") return "cancelled";
  return "error";
}

function clamp01(n) {
  if (!Number.isFinite(n)) return 0;
  return Math.min(1, Math.max(0, n));
}
