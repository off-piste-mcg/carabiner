// Pure NDJSON line-buffering: turns a stream of decoded text chunks into a sequence of
// parsed JSON objects, correctly handling a line split across a chunk boundary.
//
// Deliberately carries no import/export syntax. worker.js is a CLASSIC (non-module)
// background service worker — see worker.js's own header comment for why — and loads
// this file with importScripts("ndjson.js"), which throws a SyntaxError on `export` at
// parse time. The plain function declaration below becomes a global in the worker's
// scope once imported. extension/test/ndjson.test.js evaluates this exact file (not a
// re-implementation of it) so the tests stay honest about the code that actually ships.

/**
 * Feed one decoded text chunk into a buffer, returning any complete JSON lines found
 * plus the new remainder to carry into the next call.
 *
 * @param {string} buffer leftover partial line from the previous call
 * @param {string} chunk newly decoded text
 * @returns {{events: any[], buffer: string}}
 */
function feedNDJSON(buffer, chunk) {
  const combined = buffer + chunk;
  const lines = combined.split("\n");
  const remainder = lines.pop() ?? "";
  const events = [];
  for (const line of lines) {
    const trimmed = line.trim();
    if (!trimmed) continue;
    try {
      events.push(JSON.parse(trimmed));
    } catch (_) {
      // A malformed line must not crash the worker mid-stream — skip it silently.
    }
  }
  return { events, buffer: remainder };
}
