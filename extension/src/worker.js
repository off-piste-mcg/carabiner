// CLASSIC (non-module) background service worker — deliberately NOT `"type": "module"`
// in manifest.json. This file has no top-level `import`, so the module loader buys
// nothing, and Safari's web-extension converter warns that `background.type: "module"`
// is not supported by that Safari version. Rather than ship a key that only helps one
// browser and silently breaks loading in the other, this stays classic and pulls in its
// one pure helper via importScripts — the traditional, broadly-supported way for a
// classic worker to load another script. See ndjson.js's header for the other half of
// this.
importScripts("ndjson.js");

const ENDPOINT = "http://127.0.0.1:51847";

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
    // The app isn't running. Launch it via the URL scheme, then retry once. A second
    // failure here propagates out of run() and is handled by the onMessage listener's
    // own .catch above.
    await launchApp();
    await new Promise((r) => setTimeout(r, 2500));
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

function post(msg) {
  return fetch(`${ENDPOINT}/grab`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ url: msg.url, browser: msg.browser }),
  });
}

async function launchApp() {
  // No return channel and a one-time browser prompt — acceptable purely as a launcher.
  const tab = await chrome.tabs.create({ url: "carabiner://launch", active: false });
  setTimeout(() => chrome.tabs.remove(tab.id).catch(() => {}), 1500);
}

function relay(tabId, message) {
  if (tabId) chrome.tabs.sendMessage(tabId, message).catch(() => {});
}

// Announce ourselves so the onboarding row can turn green on a real connection.
chrome.runtime.onInstalled.addListener(ping);
chrome.runtime.onStartup.addListener(ping);
function ping() {
  const browser = navigator.userAgent.includes("Safari") && !navigator.userAgent.includes("Chrome")
    ? "safari" : "chrome";
  fetch(`${ENDPOINT}/health?browser=${browser}`).catch(() => {});
}
