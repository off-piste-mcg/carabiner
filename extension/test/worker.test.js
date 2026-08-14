import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath, pathToFileURL } from "node:url";
import path from "node:path";

// worker.js under Node — Finding 3(b), final review. Zero tests existed for the two
// pieces of wiring the finding names explicitly: 409 routing (a grab already running) and
// NDJSON stream consumption. Exercises the REAL shipped extension/src/worker.js, not a
// copy — same mandate as content.test.js.
//
// worker.js is a CLASSIC (non-module) service worker that loads its dependencies via
// `importScripts("ndjson.js", "browser.js")` — a worker-only global Node doesn't have.
// `feedNDJSON`/`detectBrowser` are extracted from the real files with `new Function`
// (exactly ndjson.test.js's own established pattern, for the identical reason: neither
// file has `export`), and `globalThis.importScripts` is mocked to hand worker.js those
// same extracted values under the names it asks for — not a reimplementation of either
// function, just a stand-in for the worker-global loading mechanism.

const srcDir = path.join(path.dirname(fileURLToPath(import.meta.url)), "..", "src");

const { feedNDJSON } = new Function(
  `${readFileSync(path.join(srcDir, "ndjson.js"), "utf8")}\nreturn { feedNDJSON };`
)();
const { detectBrowser } = new Function(
  `${readFileSync(path.join(srcDir, "browser.js"), "utf8")}\nreturn { detectBrowser };`
)();

/**
 * Loads a fresh copy of worker.js with `chrome` and `fetch` mocked. `fetchImpl` stands in
 * for the one real network call worker.js makes (`fetch(ENDPOINT + ...)`).
 */
async function loadWorker(fetchImpl) {
  globalThis.importScripts = (...files) => {
    for (const f of files) {
      if (f === "ndjson.js") globalThis.feedNDJSON = feedNDJSON;
      else if (f === "browser.js") globalThis.detectBrowser = detectBrowser;
      else throw new Error(`worker.test.js's importScripts mock doesn't know "${f}"`);
    }
  };
  globalThis.fetch = fetchImpl;
  // Node's own `navigator` global is a non-configurable getter — same workaround as
  // content.test.js. worker.js's `ping()` reads `navigator.userAgent`, but nothing here
  // exercises `ping()` (it only fires on onInstalled/onStartup, which this harness never
  // triggers), so the exact value doesn't matter — only that reading it doesn't throw.
  Object.defineProperty(globalThis, "navigator", {
    value: { userAgent: "Mozilla/5.0 Chrome/1.0 Safari/1.0" }, configurable: true,
  });

  let messageListener = null;
  const relayed = []; // every chrome.tabs.sendMessage(tabId, message) call
  const tabsCreated = [];
  globalThis.chrome = {
    runtime: {
      onMessage: { addListener: (fn) => { messageListener = fn; } },
      onInstalled: { addListener: () => {} },
      onStartup: { addListener: () => {} },
    },
    tabs: {
      sendMessage: async (tabId, message) => { relayed.push({ tabId, message }); },
      create: async (opts) => { tabsCreated.push(opts); return { id: 999 }; },
      remove: async () => {},
    },
  };

  const url = pathToFileURL(path.join(srcDir, "worker.js")).href + `?t=${Date.now()}_${Math.random()}`;
  await import(url);

  return {
    relayed,
    tabsCreated,
    /** Drives the real onMessage listener exactly as chrome would, capturing the ack. */
    send: (msg, tabId = 1) => {
      let ack;
      messageListener(msg, { tab: { id: tabId } }, (reply) => { ack = reply; });
      return ack;
    },
  };
}

/** Builds a fetch-Response-shaped object streaming the given raw NDJSON lines one read() at a time. */
function streamingResponse(status, lines) {
  const encoder = new TextEncoder();
  let i = 0;
  return {
    status,
    ok: status >= 200 && status < 300,
    body: {
      getReader: () => ({
        read: async () => {
          if (i >= lines.length) return { done: true, value: undefined };
          return { done: false, value: encoder.encode(lines[i++]) };
        },
      }),
    },
  };
}

/** Polls until `predicate()` is truthy — `run()`'s async work continues after `send()` returns. */
async function waitFor(predicate, { timeout = 1000, interval = 5 } = {}) {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) {
    const v = predicate();
    if (v) return v;
    await new Promise((r) => setTimeout(r, interval));
  }
  assert.fail(`waitFor: condition never became true within ${timeout}ms`);
}

test("a 409 from the app relays a plain 'already running' error, not the raw status", async () => {
  const worker = await loadWorker(async () => streamingResponse(409, []));
  const ack = worker.send({ type: "grab", id: "g1", url: "https://www.instagram.com/p/x/", browser: "chrome" });
  assert.deepEqual(ack, { accepted: true }, "the click's own ack must not wait on the fetch");

  const done = await waitFor(() => worker.relayed.find((r) => r.message.type === "done"));
  assert.equal(done.tabId, 1);
  assert.equal(done.message.id, "g1");
  assert.equal(done.message.result, "error");
  assert.equal(done.message.message, "A grab is already running");
});

test("NDJSON progress and the terminal result are relayed as they stream in, tagged with the grab id", async () => {
  const lines = [
    '{"stage":"probe"}\n',
    '{"stage":"download","pct":42.5}\n',
    '{"result":"ok","files":1,"name":"C1_fixed.mp4"}\n',
  ];
  const worker = await loadWorker(async () => streamingResponse(200, lines));
  worker.send({ type: "grab", id: "g2", url: "https://www.instagram.com/p/x/", browser: "chrome" });

  const done = await waitFor(() => worker.relayed.find((r) => r.message.type === "done"));
  const progress = worker.relayed.filter((r) => r.message.type === "progress").map((r) => r.message);

  assert.equal(progress.length, 2);
  assert.equal(progress[0].stage, "probe");
  assert.equal(progress[0].id, "g2");
  assert.equal(progress[1].stage, "download");
  assert.equal(progress[1].pct, 42.5);

  assert.equal(done.message.id, "g2");
  assert.equal(done.message.result, "ok");
  assert.equal(done.message.name, "C1_fixed.mp4");
});

test("a stream that ends without ever delivering a result line is reported as a connection failure, not silence", async () => {
  // The MV3 worker is ephemeral and the connection can drop mid-grab — worker.js's own
  // fallback for exactly this (not a keepalive hack: see its header comment) must fire so
  // the button doesn't spin forever waiting for a result line that is never coming.
  const worker = await loadWorker(async () => streamingResponse(200, ['{"stage":"probe"}\n']));
  worker.send({ type: "grab", id: "g3", url: "https://www.instagram.com/p/x/", browser: "chrome" });

  const done = await waitFor(() => worker.relayed.find((r) => r.message.type === "done"));
  assert.equal(done.message.result, "error");
  assert.equal(done.message.message, "Connection closed unexpectedly");
});

test("a connection failure launches the app and retries once before giving up", async () => {
  let calls = 0;
  const worker = await loadWorker(async () => {
    calls += 1;
    if (calls === 1) throw new Error("connection refused");
    return streamingResponse(200, ['{"result":"ok","files":1,"name":"C1_fixed.mp4"}\n']);
  });
  worker.send({ type: "grab", id: "g4", url: "https://www.instagram.com/p/x/", browser: "chrome" });

  const done = await waitFor(() => worker.relayed.find((r) => r.message.type === "done"), { timeout: 5000 });
  assert.equal(done.message.result, "ok");
  assert.equal(calls, 2, "the app-launch retry must actually call fetch a second time");
  assert.equal(worker.tabsCreated.length, 1);
  assert.equal(worker.tabsCreated[0].url, "carabiner://launch");
});
