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
const { waitForApp } = new Function(
  `${readFileSync(path.join(srcDir, "launch.js"), "utf8")}\nreturn { waitForApp };`
)();

/**
 * Loads a fresh copy of worker.js with `chrome` and `fetch` mocked. `fetchImpl` stands in
 * for the one real network call worker.js makes (`fetch(ENDPOINT + ...)`).
 */
async function loadWorker(fetchImpl, { launchTimeoutMs, launchProbeTimeoutMs } = {}) {
  globalThis.importScripts = (...files) => {
    for (const f of files) {
      if (f === "ndjson.js") globalThis.feedNDJSON = feedNDJSON;
      else if (f === "browser.js") globalThis.detectBrowser = detectBrowser;
      else if (f === "launch.js") globalThis.waitForApp = waitForApp;
      else throw new Error(`worker.test.js's importScripts mock doesn't know "${f}"`);
    }
  };
  // Documented test seam: worker.js reads this global for its cold-launch bound, falling
  // back to the real 30s. Without it, pinning the give-up path would cost 30 real seconds
  // per run. Nothing outside the worker can set it — a service worker global is not
  // reachable from a page.
  globalThis.CARABINER_LAUNCH_TIMEOUT_MS = launchTimeoutMs;
  globalThis.CARABINER_LAUNCH_PROBE_TIMEOUT_MS = launchProbeTimeoutMs;
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
  const tabsRemoved = [];
  const tabsActivated = []; // chrome.tabs.update(id, {active:true}) — focus restoration
  globalThis.chrome = {
    runtime: {
      onMessage: { addListener: (fn) => { messageListener = fn; } },
      onInstalled: { addListener: () => {} },
      onStartup: { addListener: () => {} },
    },
    tabs: {
      sendMessage: async (tabId, message) => { relayed.push({ tabId, message }); },
      create: async (opts) => { tabsCreated.push(opts); return { id: 999 }; },
      remove: async (id) => { tabsRemoved.push(id); },
      update: async (id, opts) => { if (opts?.active) tabsActivated.push(id); },
    },
  };

  const url = pathToFileURL(path.join(srcDir, "worker.js")).href + `?t=${Date.now()}_${Math.random()}`;
  await import(url);

  return {
    relayed,
    tabsCreated,
    tabsRemoved,
    tabsActivated,
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

/**
 * A fetch stand-in that models a cold app: /grab refuses until `upAt` ms have passed, and
 * /health answers only once the app is "up". Mirrors the real cold-launch shape, where the
 * app starts when a HUMAN answers Chrome's dialog, some seconds after the tab appears.
 */
function coldApp({ upAtMs, lines = ['{"result":"ok","files":1,"name":"C1_fixed.mp4"}\n'] }) {
  const t0 = Date.now();
  const grabs = [];
  const healthCalls = []; // every health request's init, so its SHAPE can be asserted
  const impl = async (url, init) => {
    const up = Date.now() - t0 >= upAtMs;
    if (String(url).includes("/health")) {
      healthCalls.push(init);
      if (!up) throw new Error("connection refused");
      return { ok: true, status: 200 };
    }
    grabs.push(Date.now() - t0);
    if (!up) throw new Error("connection refused");
    return streamingResponse(200, lines);
  };
  impl.grabs = grabs;
  impl.healthCalls = healthCalls;
  return impl;
}

test("a connection failure launches the app in a VISIBLE tab — a background tab hides the prompt", async () => {
  // The measured root cause of item 11 (2026-08-18). `carabiner://launch` does not start
  // the app; it makes Chrome show a TAB-MODAL "Open Carabiner?" dialog. Created with
  // active:false, that dialog renders on a tab the user is not looking at, so it is never
  // seen and never answered — the app never starts and nothing explains why.
  const fetchImpl = coldApp({ upAtMs: 300 });
  const worker = await loadWorker(fetchImpl, { launchTimeoutMs: 5000 });
  worker.send({ type: "grab", id: "g4", url: "https://www.instagram.com/p/x/", browser: "chrome" });

  await waitFor(() => worker.tabsCreated.length === 1);
  assert.equal(worker.tabsCreated[0].url, "carabiner://launch");
  assert.equal(worker.tabsCreated[0].active, true, "the launch tab must be foregrounded or the prompt is invisible");
  // Run to completion before returning. Every loadWorker() shares one set of globals, so a
  // still-polling run() from a finished test would keep firing against the NEXT test's
  // mocks — which is exactly what it did, holding the whole file open for the full bound.
  await waitFor(() => worker.relayed.find((r) => r.message.type === "done"));
});

test("the retry waits for the app to actually answer, not a fixed 2500ms — the red X that shipped", async () => {
  // Measured live: the human took long enough to read the dialog that the old fixed 2500ms
  // wait expired first. The app came up fine; the button still showed a red X and nothing
  // downloaded. 4000ms here is past that old budget on purpose — revert the fix and this
  // test goes red.
  const fetchImpl = coldApp({ upAtMs: 4000 });
  const worker = await loadWorker(fetchImpl, { launchTimeoutMs: 20000 });
  worker.send({ type: "grab", id: "g5", url: "https://www.instagram.com/p/x/", browser: "chrome" });

  const done = await waitFor(() => worker.relayed.find((r) => r.message.type === "done"), { timeout: 15000 });
  assert.equal(done.message.result, "ok", "a slow human must not be reported as a failed grab");
  assert.ok(fetchImpl.grabs.length >= 2, "the grab must actually be retried once the app is up");
});

test("once the app is up the launch tab is closed and focus returns to the post", async () => {
  const worker = await loadWorker(coldApp({ upAtMs: 300 }), { launchTimeoutMs: 5000 });
  worker.send({ type: "grab", id: "g6", url: "https://www.instagram.com/p/x/", browser: "chrome" }, 77);

  await waitFor(() => worker.relayed.find((r) => r.message.type === "done"));
  assert.deepEqual(worker.tabsRemoved, [999], "the launch tab is litter once it has done its job");
  assert.deepEqual(worker.tabsActivated, [77], "the user was on the post; put them back there");
});

test("the health probe is a non-simple request, so Chrome attaches an Origin", async () => {
  // THE bug behind item 11's last failure, measured in Chrome's worker console 2026-08-18:
  //     GET  /health → 403     POST /health (content-type: application/json) → 200
  // /health is origin-gated, and Chrome sends no Origin on a simple GET from an extension
  // worker (host permissions bypass CORS, so there is nothing to attach one to). A bare GET
  // is 403 forever — the probe could not have succeeded at ANY timeout, against an app that
  // was demonstrably up 2 seconds in.
  const fetchImpl = coldApp({ upAtMs: 300 });
  const worker = await loadWorker(fetchImpl, { launchTimeoutMs: 5000 });
  worker.send({ type: "grab", id: "g9", url: "https://www.instagram.com/p/x/", browser: "chrome" });

  await waitFor(() => worker.relayed.find((r) => r.message.type === "done"));
  assert.ok(fetchImpl.healthCalls.length > 0, "the launch wait must actually probe /health");
  for (const init of fetchImpl.healthCalls) {
    assert.equal(init?.method, "POST", "a simple GET carries no Origin and is 403'd forever");
    assert.equal(init?.headers?.["content-type"], "application/json",
      "the content-type is what makes it non-simple — without it Chrome sends no Origin");
  }
});

test("a health probe that HANGS is abandoned, so the bound still fires — measured field failure", async () => {
  // 2026-08-18, console-less cold run: the app was up 2 seconds after the launch tab
  // appeared, yet the wait never returned and the 120s bound never fired. The probe's
  // fetch hung rather than resolving or rejecting, and the deadline is only consulted
  // between probes. Without probeTimeoutMs threaded through from here, this test hangs
  // forever instead of failing — which is precisely how the bug presented to the user.
  const worker = await loadWorker(
    async (url) => {
      if (String(url).includes("/health")) return new Promise(() => {}); // hangs, like the real one did
      throw new Error("connection refused");
    },
    { launchTimeoutMs: 800, launchProbeTimeoutMs: 200 }
  );
  worker.send({ type: "grab", id: "g8", url: "https://www.instagram.com/p/x/", browser: "chrome" });

  const done = await waitFor(() => worker.relayed.find((r) => r.message.type === "done"), { timeout: 8000 });
  assert.equal(done.message.result, "error");
  assert.match(done.message.message, /Open Carabiner/);
});

test("an unanswered prompt gives up at the bound, says what to do, and LEAVES the tab open", async () => {
  // Gotcha #33: the bound must be a real bound. But closing the tab on the way out would
  // destroy the very dialog the user still has to answer — the original bug, just later.
  const worker = await loadWorker(coldApp({ upAtMs: Infinity }), { launchTimeoutMs: 600 });
  worker.send({ type: "grab", id: "g7", url: "https://www.instagram.com/p/x/", browser: "chrome" });

  const done = await waitFor(() => worker.relayed.find((r) => r.message.type === "done"), { timeout: 5000 });
  assert.equal(done.message.result, "error");
  assert.match(done.message.message, /Open Carabiner/, "the error must name the thing the user has to click");
  assert.deepEqual(worker.tabsRemoved, [], "the unanswered dialog must survive our giving up");
});
