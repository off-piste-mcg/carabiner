// Pure mapping from a progress/done event (the wire shape written by
// app/Carabiner/Server/GrabEvent.swift: {"stage":...}, {"stage":"download","pct":42.5},
// {"stage":"item","index":2,"total":5}, {"result":"ok"|"error"|"cancelled",...}) to how
// the in-page button's ring should react.
//
// Extracted into its own module — rather than left inline in content.js's message
// listener — so the one rule that matters most can be unit-tested without a DOM: the
// ring means "downloading", so `probe` and `prompt` ("still thinking" and "waiting for
// you") must NOT advance it. The app's own menu-bar ring follows the same rule for the
// same reason (see ProgressModel.swift's ring-begins-on-first-download-marker logic,
// which this module deliberately mirrors for the extension's own ring).
//
// Loaded by content.js via a dynamic import() of this file's web-accessible-resource URL
// (content.js is a classic content script that stays in the isolated world — see its own
// header comment for why a page-context `type="module"` <script> tag, this project's
// first draft, was wrong) — a dynamic import from a content script is unaffected by the
// background-worker module-loading constraint documented in worker.js and ndjson.js, so,
// unlike ndjson.js, this file needs no importScripts workaround and can use normal export.

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
    case "save":
      return 1;
    case "probe":
    case "prompt":
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
