// CLASSIC (non-module) background service worker — deliberately NOT `"type": "module"`
// in manifest.json. This file has no top-level `import`, so the module loader buys
// nothing, and Safari's web-extension converter warns that `background.type: "module"`
// is not supported by that Safari version. Rather than ship a key that only helps one
// browser and silently breaks loading in the other, this stays classic and pulls in its
// one pure helper via importScripts — the traditional, broadly-supported way for a
// classic worker to load another script. See ndjson.js's header for the other half of
// this. browser.js (detectBrowser) is loaded the same way, for the same reason — see its
// own header for how content.js gets the identical function without a second copy.
importScripts("ndjson.js", "browser.js", "launch.js");

const ENDPOINT = "http://127.0.0.1:51847";

// How long to wait for a human to answer Chrome's "Open Carabiner?" dialog. The wait is
// gated on a person noticing a new tab, reading it and clicking — not on the app's own
// 0.21s cold start. 120s rather than 30s because a real user measurably took longer than
// 30s, and the bound expiring is indistinguishable to them from the app being broken. The
// button's own watchdog goes amber ("no news yet") at 90s, which is the honest thing to
// show while a dialog is still unanswered, so this bound deliberately sits past it: amber
// first, a definite error only after. The global is a documented test seam so the give-up
// path can be pinned without burning 120 real seconds (worker.test.js); nothing outside the
// worker can reach a service-worker global.
const LAUNCH_TIMEOUT_MS = globalThis.CARABINER_LAUNCH_TIMEOUT_MS ?? 120000;
const LAUNCH_POLL_MS = 250;
// Bound on ONE health probe. /health answers in ~2ms when the app is up, so 2s is far
// beyond any legitimate answer and only ever cuts off a hung socket. Same documented test
// seam as the overall bound, so the hang path can be pinned without a multi-second test.
const LAUNCH_PROBE_TIMEOUT_MS = globalThis.CARABINER_LAUNCH_PROBE_TIMEOUT_MS ?? 2000;

// The ONLY place that talks to the app. A content script's fetch would carry
// instagram.com as its origin and the app would reject it — correctly (measured).
chrome.runtime.onMessage.addListener((msg, sender, sendResponse) => {
  if (msg?.type !== "grab") return false;
  const tabId = sender.tab?.id;
  const id = msg.id;
  run(msg, tabId).catch((e) => {
    relay(tabId, { type: "done", id, result: "error", message: String(e) });
  });
  // Explicit and unconditional (fix round 1, Finding 3): this is the ack content.js
  // checks for (`reply?.accepted`) to tell "the worker is alive and got the click" apart
  // from a worker that never registered at all — the exact Safari importScripts risk
  // this extension takes on. If the worker is dead, this listener never runs, sendMessage
  // never gets a reply, and chrome.runtime.lastError fires on the sender's side instead
  // (content.js checks that too) — this ack is the "worker is fine" half of that pair.
  sendResponse({ accepted: true });
  return true; // keep the message channel open for the async reply
});

async function run(msg, tabId) {
  // Threaded through every relayed message so content.js can route it to the one button
  // that owns this grab, not "whichever button was clicked most recently" (fix round 1,
  // Finding 2 — a single implicit owner cross-wired two buttons on one post).
  const id = msg.id;
  let response;
  try {
    response = await post(msg);
  } catch (_) {
    // The app isn't running. Show the launch prompt and wait for the user to answer it,
    // then retry once. A second failure here propagates out of run() and is handled by the
    // onMessage listener's own .catch above.
    if (!(await launchApp(tabId))) {
      return relay(tabId, {
        type: "done", id, result: "error",
        message: "Carabiner isn’t running — approve “Open Carabiner?” in the new tab, then click again",
      });
    }
    response = await post(msg);
  }
  if (response.status === 409) {
    return relay(tabId, { type: "done", id, result: "error", message: "A grab is already running" });
  }
  if (!response.ok) {
    return relay(tabId, { type: "done", id, result: "error", message: `Carabiner said ${response.status}` });
  }

  const reader = response.body.getReader();
  const decoder = new TextDecoder();
  let buffer = "";
  let sawResult = false;

  const consume = (events) => {
    for (const event of events) {
      // `...event` FIRST (fix round 2 minor): if a future GrabEvent ever emitted a field
      // literally named `type` or `id`, spreading it AFTER ours would silently clobber
      // the routing key and strand the button. GrabEvent.swift emits neither field today,
      // so this is currently latent, not reachable — but which side wins should not
      // depend on that staying true forever.
      if (event.result) {
        sawResult = true;
        relay(tabId, { ...event, type: "done", id });
      } else {
        relay(tabId, { ...event, type: "progress", id });
      }
    }
  };

  for (;;) {
    const { value, done } = await reader.read();
    if (done) break;
    const chunkText = decoder.decode(value, { stream: true });
    const parsed = feedNDJSON(buffer, chunkText);
    buffer = parsed.buffer;
    consume(parsed.events);
  }
  // decoder.decode() with no arguments flushes any bytes still buffered for an incomplete
  // multi-byte UTF-8 sequence split across the very last chunk boundary (fix round 1,
  // minor) — without this, a trailing character could be silently lost instead of
  // completing the final line.
  buffer += decoder.decode();
  // The server always terminates its own last line with "\n" (GrabEvent.swift's encode
  // always appends one), but a connection that drops mid-write could still leave an
  // unterminated partial line sitting in `buffer` — give it one more chance to parse.
  if (buffer.trim()) consume(feedNDJSON(buffer, "\n").events);

  // The MV3 service worker is ephemeral, and the stream can end (the server closing the
  // connection, a network hiccup, the app quitting mid-grab) without ever delivering the
  // terminal `result` line. The button must not sit spinning forever waiting for
  // something that is never coming — this is what makes that failure visible instead of
  // silent. This is a real fallback for a real failure mode within this function's
  // control; it is not a keepalive hack, and none was added speculatively for the
  // separate, unverified risk of the worker being killed outright mid-stream (content.js's
  // own watchdog — fix round 1, Finding 6 — is what covers that side).
  if (!sawResult) {
    relay(tabId, { type: "done", id, result: "error", message: "Connection closed unexpectedly" });
  }
}

/**
 * Asks the app whether it is alive, in a request shape that actually carries an `Origin`.
 *
 * Measured in Chrome's worker console, 2026-08-18, app running:
 *     GET  /health → 403
 *     POST /health (content-type: application/json) → 200
 *
 * `/health` is origin-gated (GrabServer.health → GrabGate.check), and Chrome does NOT send
 * an `Origin` header on a simple GET from an extension worker — host permissions let it
 * bypass CORS entirely, so there is nothing to attach one to. A bare GET is therefore 403
 * FOREVER, however long you wait for it.
 *
 * POST with `content-type: application/json` is deliberately the same shape `/grab` already
 * uses: it is a non-simple request, so the `Origin` is present, and Safari already
 * preflights exactly this successfully. Adding a custom header to a GET would also work in
 * Chrome and would silently break Safari, whose preflight advertises no allowed headers —
 * gotcha #29, the same trap in the same file.
 */
function health(signal) {
  return fetch(`${ENDPOINT}/health?browser=${detectBrowser()}`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: "{}",
    signal,
  });
}

function post(msg) {
  return fetch(`${ENDPOINT}/grab`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ url: msg.url, browser: msg.browser }),
  });
}

let launchInFlight = null;

/**
 * Cold-starts the app and resolves true once it answers, false if the bound is reached.
 *
 * Three properties here are load-bearing, all three measured on 2026-08-18 (item 11):
 *
 *  - `active: true`. Navigating to `carabiner://launch` does NOT start the app: it makes
 *    Chrome show a TAB-MODAL "Open Carabiner?" dialog, which the user must click. On a
 *    background tab that dialog is never visible, so the app never starts and the failure
 *    is completely silent. This was the original bug.
 *  - We wait for /health rather than a fixed delay. The old code slept 2500ms — sized
 *    against the app's own 0.21s cold start — and so gave up while the dialog was still on
 *    screen. Measured: the app started fine and the grab still failed with a red X.
 *  - On the give-up path the tab STAYS. Closing it would destroy a dialog the user has not
 *    answered yet, which is the original bug again, just 30 seconds later.
 *
 * Note there is no "always allow" checkbox on that dialog, so this is not a one-time cost:
 * every cold launch prompts. The Login Item in the app's onboarding is the real answer —
 * this path is the fallback for when Carabiner is not already running.
 */
async function launchApp(returnToTabId) {
  // Two buttons clicked at once must not open two launch tabs and two dialogs.
  if (launchInFlight) return launchInFlight;
  launchInFlight = (async () => {
    const tab = await chrome.tabs.create({ url: "carabiner://launch", active: true });
    const up = await waitForApp({
      // AbortSignal.timeout is belt to waitForApp's braces: the race abandons a hung probe,
      // but without this the underlying socket stays open and leaks one connection per
      // poll. Measured 2026-08-18: this fetch really does hang against the just-launched
      // app rather than resolving or rejecting.
      probe: async () => (await health(AbortSignal.timeout(LAUNCH_PROBE_TIMEOUT_MS))).ok,
      timeoutMs: LAUNCH_TIMEOUT_MS,
      intervalMs: LAUNCH_POLL_MS,
      probeTimeoutMs: LAUNCH_PROBE_TIMEOUT_MS,
      sleep: (ms) => new Promise((r) => setTimeout(r, ms)),
      now: Date.now,
    });
    if (up) {
      await chrome.tabs.remove(tab.id).catch(() => {});
      // The user was looking at a post; the launch tab stole focus. Put them back.
      if (returnToTabId) await chrome.tabs.update(returnToTabId, { active: true }).catch(() => {});
    }
    return up;
  })();
  try {
    return await launchInFlight;
  } finally {
    launchInFlight = null;
  }
}

function relay(tabId, message) {
  if (tabId) chrome.tabs.sendMessage(tabId, message).catch(() => {});
}

// Announce ourselves so the onboarding row can turn green on a real connection.
chrome.runtime.onInstalled.addListener(ping);
chrome.runtime.onStartup.addListener(ping);
function ping() {
  // Was a bare GET, which Chrome answers 403 to — see health()'s comment. That means this
  // check-in has never once reached the app from Chrome, and the onboarding window's Chrome
  // row could never turn green. Safari sends an Origin (it preflights, gotcha #29), which
  // is why only Safari's row was ever seen working.
  health().catch(() => {});
}
