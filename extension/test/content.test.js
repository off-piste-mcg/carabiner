import { test } from "node:test";
import assert from "node:assert/strict";
import { JSDOM } from "jsdom";
import { readFileSync } from "node:fs";
import { fileURLToPath, pathToFileURL } from "node:url";
import path from "node:path";

// content.js under jsdom — Finding 3(b), final review. Earlier reviewers drove this file
// under jsdom "by hand" and never committed the harness; this is that harness, exercising
// the REAL shipped extension/src/content.js (not a copy, not a rewrite).
//
// The two obstacles this works around, both load-bearing:
//
// 1. content.js is a CLASSIC (non-module) content script that loads its ESM dependencies
//    via `await import(chrome.runtime.getURL("src/shortcode.js"))` — see the file's own
//    header for why. Rather than fight jsdom's vm-based script execution (which does not
//    reliably support dynamic `import()` from a classic inline script), this installs
//    jsdom's `window` as Node's OWN globals and lets Node's native ESM loader `import()`
//    content.js directly. Mocking `chrome.runtime.getURL` to resolve to a real `file://`
//    URL under extension/src/ means content.js's own dynamic imports load the ACTUAL
//    shortcode.js/containers.js/grabTracker.js this branch ships — not stand-ins.
// 2. `makeButton` uses a CLOSED shadow root ("Instagram's CSS cannot reach our button and
//    ours cannot leak into the page" — content.js's own comment) — by spec, `host.shadowRoot`
//    returns null for closed mode, so there is no legitimate outside handle to the button.
//    `attachShadow` is monkey-patched here to record (host -> root) pairs as a side
//    channel for assertions only; nothing about the extension's own closed-ness changes —
//    `host.shadowRoot` still reads null everywhere else.

const srcDir = path.join(path.dirname(fileURLToPath(import.meta.url)), "..", "src");

// browser.js (detectBrowser) has no export — worker.js loads it via importScripts, and in
// the real extension content.js sees it as a plain global because manifest.json lists
// browser.js immediately before content.js in the same content_scripts[].js array, so
// both execute as classic scripts sharing one global scope (see browser.js's own header).
// Node's `import()` cannot reproduce that — every dynamically imported file gets its own
// module scope regardless of whether it has `export` — so this evaluates the exact
// shipped source with `new Function`, exactly like ndjson.test.js does for the identical
// reason, and installs the result on `globalThis` to stand in for "classic scripts share
// a global scope" before content.js's own dynamic import chain runs.
const browserJsSrc = readFileSync(path.join(srcDir, "browser.js"), "utf8");
globalThis.detectBrowser = new Function(`${browserJsSrc}\nreturn { detectBrowser };`)().detectBrowser;

// content.js's top-level statements reference `document`/`chrome` etc. as bare globals,
// looked up on `globalThis` at the moment each one actually RUNS — not bound to whatever
// they pointed at when the surrounding function was defined. That matters here because
// content.js schedules ongoing async work against them: `scheduleScan`'s
// `requestAnimationFrame`, the `MutationObserver`, and — the one that actually bit this
// suite — `grabTracker.js`'s 90-second watchdog `setTimeout` per tracked grab. A PREVIOUS
// test's callback firing after the NEXT test has already reassigned these globals would
// run against the wrong document/chrome entirely, and a dangling 90s `setTimeout` alone
// was measured to hold the whole four-test suite open for ~90 real seconds (the
// process-lifetime, ref'd Node timer doesn't care that the test that armed it already
// finished). Closing the previous jsdom window before the next one is installed — jsdom's
// documented way to stop a window's own pending timers — removes both problems at once;
// tracked here (module scope, not per-test) so it runs deterministically before every
// `loadContentScript` after the first.
let previousWindow = null;

/**
 * Loads a fresh copy of content.js against a fresh jsdom document, with jsdom installed
 * as Node's globals and `chrome` mocked. Returns handles for driving and inspecting it.
 */
async function loadContentScript(html, { url = "https://www.instagram.com/" } = {}) {
  previousWindow?.close();
  const dom = new JSDOM(html, { url, pretendToBeVisual: true });
  const { window } = dom;
  previousWindow = window;

  // Capture what a closed shadow root hides from ordinary code — see header comment (2).
  const shadowRoots = new WeakMap();
  const realAttachShadow = window.Element.prototype.attachShadow;
  window.Element.prototype.attachShadow = function (init) {
    const root = realAttachShadow.call(this, init);
    shadowRoots.set(this, root);
    return root;
  };

  // `crypto` deliberately excluded: Node's own global `crypto` (with `randomUUID()`,
  // which is all content.js's `nextId()` needs) is non-configurable and re-assigning it
  // throws — and there is nothing content.js needs from jsdom's copy that Node's doesn't
  // already provide for this one call.
  // "window" itself is on the list since the overlay refactor: content.js registers
  // scroll/resize listeners and reads window.innerWidth/innerHeight for placement — in a
  // real content script `window` always exists; this only mirrors that.
  for (const key of ["window", "document", "MutationObserver", "requestAnimationFrame", "getComputedStyle", "Node", "location"]) {
    globalThis[key] = window[key];
  }
  // `navigator` needs the same non-configurable-getter workaround as `crypto` (Node also
  // defines this one itself) — `detectBrowser()` reads `navigator.userAgent`, and jsdom's
  // default is at least Chrome-shaped, unlike Node's own.
  Object.defineProperty(globalThis, "navigator", { value: window.navigator, configurable: true });

  const sentMessages = [];
  let messageListener = null;
  let sendReplyFn = () => ({ accepted: true });
  let sendMessageThrows = false;
  globalThis.chrome = {
    runtime: {
      lastError: undefined,
      // The real trick: resolve to the ACTUAL file on disk, so content.js's own dynamic
      // import() loads the shipped module, not a copy.
      getURL: (p) => pathToFileURL(path.join(srcDir, p.replace(/^src\//, ""))).href,
      sendMessage: (msg, cb) => {
        if (sendMessageThrows) throw new Error("extension context invalidated");
        sentMessages.push(msg);
        cb?.(sendReplyFn(msg));
      },
      onMessage: { addListener: (fn) => { messageListener = fn; } },
    },
  };

  // Cache-busted so each call gets a FRESH module evaluation (a fresh MutationObserver,
  // a fresh grabTracker) rather than Node's ESM cache handing back the first run's — the
  // shipped file has no query-string awareness of its own; this is purely a test-harness
  // trick to get one execution per test.
  const moduleUrl = pathToFileURL(path.join(srcDir, "content.js")).href + `?t=${Date.now()}_${Math.random()}`;
  await import(moduleUrl);

  return {
    window,
    document: window.document,
    sentMessages,
    deliver: (msg) => messageListener?.(msg),
    setReply: (fn) => { sendReplyFn = fn; },
    setSendMessageThrows: (v) => { sendMessageThrows = v; },
    shadowOf: (host) => shadowRoots.get(host),
  };
}

/** Polls until `predicate()` is truthy, or fails the calling test via assert. */
async function waitFor(predicate, { timeout = 1000, interval = 10 } = {}) {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) {
    const v = predicate();
    if (v) return v;
    await new Promise((r) => setTimeout(r, interval));
  }
  assert.fail(`waitFor: condition never became true within ${timeout}ms`);
}

/** Every test's fixture: a single bare permalink anchor, the simplest case selectContainers accepts. */
const SINGLE_POST_HTML = `<!doctype html><body><a href="/p/C1a2b3c4/">post</a></body>`;

test("clicking an injected button sends a message carrying a grab id and the resolved permalink", async () => {
  const ctx = await loadContentScript(SINGLE_POST_HTML);
  const host = await waitFor(() => ctx.document.querySelector("[data-carabiner-host]"));
  const button = ctx.shadowOf(host).querySelector("button");
  assert.ok(button, "button must exist inside the (closed) shadow root");

  button.click();

  assert.equal(ctx.sentMessages.length, 1);
  const msg = ctx.sentMessages[0];
  assert.equal(msg.type, "grab");
  assert.equal(msg.url, "https://www.instagram.com/p/C1a2b3c4/");
  assert.equal(typeof msg.id, "string");
  assert.ok(msg.id.length > 0, "grab id must be non-empty");

  // Cleanup, not an assertion: a click that's never followed by a "done" leaves
  // grabTracker.js's 90-SECOND watchdog `setTimeout` armed for this id. That's a real
  // Node timer (content.js runs natively in this process, not inside jsdom's sandbox),
  // so an uncleared one holds the whole test file's process alive for 90 real seconds
  // after the last assertion — measured directly while writing this suite. Every other
  // test here either delivers its own "done" or never starts a tracked grab at all.
  ctx.deliver({ type: "done", id: msg.id, result: "ok" });
});

test("a done for an unknown id is ignored — the tracked button's own state is untouched", async () => {
  const ctx = await loadContentScript(SINGLE_POST_HTML);
  const host = await waitFor(() => ctx.document.querySelector("[data-carabiner-host]"));
  const shadow = ctx.shadowOf(host);
  const button = shadow.querySelector("button");

  button.click();
  assert.equal(ctx.sentMessages.length, 1);
  const realId = ctx.sentMessages[0].id;

  // The ring is showing (setRing(0.02) runs synchronously in the click handler, before
  // sendMessage) — capture that as the "before" state.
  const ringBefore = shadow.querySelector(".ring").classList.contains("hidden");
  const backgroundBefore = button.style.background;

  // A `done` for a completely different id — grabTracker.receive() must return false and
  // touch nothing belonging to the button that's actually tracked.
  ctx.deliver({ type: "done", id: "not-" + realId, result: "ok" });

  assert.equal(shadow.querySelector(".ring").classList.contains("hidden"), ringBefore,
              "an unknown-id done must not change the ring's visibility");
  assert.equal(button.style.background, backgroundBefore,
              "an unknown-id done must not settle the button (no tick/cross colour)");

  // Sanity: the REAL id still works and does settle the button — proves the assertions
  // above are actually distinguishing "ignored" from "this button can never be settled".
  ctx.deliver({ type: "done", id: realId, result: "ok" });
  assert.notEqual(button.style.background, backgroundBefore);
});

test("re-running the scan does not double-inject a second button on the same post", async () => {
  const ctx = await loadContentScript(SINGLE_POST_HTML);
  await waitFor(() => ctx.document.querySelectorAll("[data-carabiner-host]").length === 1);

  // Trigger the real MutationObserver ({childList:true, subtree:true} on document.body) —
  // not a direct call to an internal scan(), which content.js does not export. Any
  // childList mutation under body re-runs scheduleScan() -> scan() for real.
  ctx.document.body.appendChild(ctx.document.createComment("unrelated mutation"));

  // Give the coalesced (requestAnimationFrame-scheduled) re-scan a chance to run, then
  // assert the count is STILL exactly one — attach()'s live-child check must have found
  // the existing host and skipped adding another.
  await new Promise((r) => setTimeout(r, 100));
  assert.equal(ctx.document.querySelectorAll("[data-carabiner-host]").length, 1);
});

test("a dead/unregistered worker (no ack) settles the button as an error, not a permanent spin", async () => {
  // fix round 1, Finding 3's exact scenario: chrome.runtime.lastError set, no `accepted`.
  const ctx = await loadContentScript(SINGLE_POST_HTML);
  const host = await waitFor(() => ctx.document.querySelector("[data-carabiner-host]"));
  const shadow = ctx.shadowOf(host);
  const button = shadow.querySelector("button");

  ctx.setReply(() => {
    globalThis.chrome.runtime.lastError = { message: "Receiving end does not exist" };
    return undefined;
  });
  button.click();

  assert.equal(ctx.sentMessages.length, 1);
  // paint(CROSS, "rgba(200,40,40,.9)") — settle("error") — ran synchronously inside the
  // sendMessage callback.
  assert.equal(button.style.background, "rgba(200, 40, 40, 0.9)");
});

test("the page's own DOM is never written — buttons live in the overlay, not in Instagram's tree", async () => {
  // THE hydration bug, 2026-08-17, A/B-confirmed by the user: the first shipped version
  // did container.appendChild(host) + container.style.position = "relative" — writes
  // inside the React-owned tree — and Instagram itself broke (React #418 hydration
  // mismatches: skeleton feeds, broken grids, an unresponsive post modal). Extension
  // off → Instagram flawless; on → broken. This pins the structural fix: the container
  // gains no children, no attributes, no inline style — the button lives in a
  // <carabiner-overlay> appended to documentElement, OUTSIDE anything React hydrates.
  const html = `<!doctype html><body><a href="/p/C1a2b3c4/">post</a></body>`;
  const ctx = await loadContentScript(html);
  const host = await waitFor(() => ctx.document.querySelector("[data-carabiner-host]"));

  // Final review, Finding 3: the click handler READS the page (the container's dots, and
  // — since Finding 1 — location.pathname) to resolve the slide. Those reads were outside
  // this invariant's guarantee while the test never clicked, so a write added inside the
  // click handler would have sailed past the most expensive invariant in the project.
  // Clicking here puts them under it.
  ctx.shadowOf(host).querySelector("button").click();
  ctx.deliver({ type: "done", id: ctx.sentMessages[0].id, result: "ok" });  // disarm the 90s watchdog

  const anchor = ctx.document.querySelector("a[href='/p/C1a2b3c4/']");
  assert.equal(anchor.children.length, 0, "container must gain no child elements");
  assert.equal(anchor.getAttribute("style"), null, "container must gain no inline style");
  assert.ok(!anchor.contains(host), "the button host must not live inside the container");

  assert.equal(host.parentElement.tagName, "CARABINER-OVERLAY");
  assert.equal(host.parentElement.parentElement, ctx.document.documentElement,
    "the overlay hangs off documentElement, beside <body>, outside the hydrated tree");
  assert.ok(!ctx.document.body.contains(host.parentElement),
    "the overlay must not be inside <body> (Instagram's app root lives there)");
});

test("a recycled container element (same node, new href) gets a fresh button for the NEW post", async () => {
  // Virtualized lists reuse DOM nodes. With placement keyed by element, a stale mapping
  // would download the WRONG post — the worst bug this extension could have. attach()
  // must notice the url changed and rebind.
  const ctx = await loadContentScript(`<!doctype html><body><a href="/p/AAAAAAA1/">post</a></body>`);
  await waitFor(() => ctx.document.querySelector("[data-carabiner-host]"));

  const anchor = ctx.document.querySelector("a");
  anchor.setAttribute("href", "/p/BBBBBBB2/");
  ctx.document.body.appendChild(ctx.document.createComment("mutation"));  // trigger a real scan

  await waitFor(() => {
    const h = ctx.document.querySelector("[data-carabiner-host]");
    if (!h) return false;
    ctx.shadowOf(h).querySelector("button").click();
    const last = ctx.sentMessages[ctx.sentMessages.length - 1];
    if (last) ctx.deliver({ type: "done", id: last.id, result: "ok" });  // disarm the 90s watchdog
    return last && last.url === "https://www.instagram.com/p/BBBBBBB2/";
  });
  assert.equal(ctx.document.querySelectorAll("[data-carabiner-host]").length, 1,
    "rebinding must not leave the old button behind");
});

/** The real captured feed carousel — an <article> with four dots, slide 1 active. */
const FEED_CAROUSEL_HTML = readFileSync(
  new URL("./fixtures/feed-post.html", import.meta.url), "utf8");

test("a click sends the slide the user is looking at, not always slide 1", async () => {
  const ctx = await loadContentScript(FEED_CAROUSEL_HTML);
  const host = await waitFor(() => ctx.document.querySelector("[data-carabiner-host]"));
  ctx.shadowOf(host).querySelector("button").click();

  assert.equal(ctx.sentMessages.length, 1);
  assert.match(ctx.sentMessages[0].url, /\/p\/[\w-]+\/\?img_index=1$/);
  ctx.deliver({ type: "done", id: ctx.sentMessages[0].id, result: "ok" });
});

test("swiping between attach and click changes what is sent — resolution is at CLICK time", async () => {
  const ctx = await loadContentScript(FEED_CAROUSEL_HTML);
  const host = await waitFor(() => ctx.document.querySelector("[data-carabiner-host]"));

  // Simulate the user swiping to slide 3 AFTER the button was attached. This is the exact
  // sequence that shipped broken: `url` is closed over in makeButton, so a resolution done
  // at attach time cannot see this.
  ctx.document.querySelector('button[aria-current="step"]').removeAttribute("aria-current");
  ctx.document.querySelector('button[aria-label="Go to slide 3"]').setAttribute("aria-current", "step");

  ctx.shadowOf(host).querySelector("button").click();
  assert.match(ctx.sentMessages[0].url, /\/p\/[\w-]+\/\?img_index=3$/);
  ctx.deliver({ type: "done", id: ctx.sentMessages[0].id, result: "ok" });
});

/** The post the real captured feed fixture is actually about — its own permalink. */
const FEED_PERMALINK = "https://www.instagram.com/p/Db-Xe7jDlkM/";

test("on a permalink page for THIS post the address bar wins over the dots", async () => {
  const ctx = await loadContentScript(FEED_CAROUSEL_HTML,
    { url: "https://www.instagram.com/p/Db-Xe7jDlkM/?img_index=4" });
  const host = await waitFor(() => ctx.document.querySelector("[data-carabiner-host]"));
  ctx.shadowOf(host).querySelector("button").click();

  assert.equal(ctx.sentMessages[0].url, `${FEED_PERMALINK}?img_index=4`);
  ctx.deliver({ type: "done", id: ctx.sentMessages[0].id, result: "ok" });
});

test("a page URL naming a DIFFERENT post does not leak its slide index into this button", async () => {
  // Final review, Finding 1, the reachable path: opening a post modal from the feed makes
  // Instagram push /p/A/?img_index=3, while the containers BEHIND the modal keep their
  // buttons and the overlay draws them over it. location.search is page-global; the dots
  // are not. Clicking a button for post B must send B's own slide (1 in this fixture),
  // never A's 3 — that is the silent wrong-file failure this whole feature exists to end.
  const ctx = await loadContentScript(FEED_CAROUSEL_HTML,
    { url: "https://www.instagram.com/p/ZZZZZZZZZZ/?img_index=3" });
  const host = await waitFor(() => ctx.document.querySelector("[data-carabiner-host]"));
  ctx.shadowOf(host).querySelector("button").click();

  assert.equal(ctx.sentMessages[0].url, `${FEED_PERMALINK}?img_index=1`);
  ctx.deliver({ type: "done", id: ctx.sentMessages[0].id, result: "ok" });
});

test("a non-English carousel still sends the slide the user is looking at", async () => {
  // Final review, Finding 2: an English-only label parse is a silent revert to the
  // original slide-1 bug for every localized UI. End-to-end, through the real click path.
  const ctx = await loadContentScript(FEED_CAROUSEL_HTML);
  const host = await waitFor(() => ctx.document.querySelector("[data-carabiner-host]"));
  ctx.document.querySelector('button[aria-current="step"]').removeAttribute("aria-current");
  const dutch = ctx.document.querySelector('button[aria-label="Go to slide 3"]');
  dutch.setAttribute("aria-current", "step");
  dutch.setAttribute("aria-label", "Ga naar dia 3");

  ctx.shadowOf(host).querySelector("button").click();
  assert.equal(ctx.sentMessages[0].url, `${FEED_PERMALINK}?img_index=3`);
  ctx.deliver({ type: "done", id: ctx.sentMessages[0].id, result: "ok" });
});

test("swiping does not rebind the button — the slide index is not baked into the dedup key", async () => {
  const ctx = await loadContentScript(FEED_CAROUSEL_HTML);
  const host = await waitFor(() => ctx.document.querySelector("[data-carabiner-host]"));

  // The `aria-current` attribute change alone does NOT trigger a rescan — content.js's
  // MutationObserver is `{ childList: true, subtree: true }`, which ignores attribute
  // mutations entirely. Without a real childList mutation this test would pass no matter
  // what attach()/the dedup key did, because scan() would simply never re-run. So: change
  // the active dot (what a real swipe changes), AND separately force the rescan the same
  // way "re-running the scan does not double-inject" above does — append a throwaway node
  // under body, which the observer's childList/subtree does see.
  ctx.document.querySelector('button[aria-current="step"]').removeAttribute("aria-current");
  ctx.document.querySelector('button[aria-label="Go to slide 3"]').setAttribute("aria-current", "step");
  ctx.document.body.appendChild(ctx.document.createComment("unrelated mutation"));
  // Give the coalesced (requestAnimationFrame-scheduled) rescan a chance to run before
  // counting.
  await new Promise((r) => setTimeout(r, 100));

  assert.equal(ctx.document.querySelectorAll("[data-carabiner-host]").length, 1,
               "a swipe must not create a second button");
  assert.equal(ctx.document.querySelector("[data-carabiner-host]"), host,
               "and must not replace the existing one — if the slide index were baked into " +
               "the dedup key, this rescan would compute a different url, see " +
               "existing.url !== url, and destroy/recreate the button");
});

// --- Placement (2026-08-19) -------------------------------------------------------------
// The button moved from the post's top-right corner to beside Instagram's Save icon. These
// pin the WIRING, which actionBar.test.js cannot: findSaveButton() can be perfect while
// place() never calls it, and the corner placement would look entirely correct in every
// other test (gotcha #34 — the reason the hardcoded-.chrome onboarding bug shipped).
//
// The markup here is synthetic ON PURPOSE, unlike actionBar.test.js's, which runs against
// the real captured fixtures. What is being tested here is "does place() anchor to whatever
// findSaveButton returns", not "does the selector match Instagram" — that second question
// is only honestly answerable against real markup, and is answered there.

const ACTION_BAR_HTML = `<!doctype html><body><article>
  <a href="/p/C1a2b3c4/">post</a>
  <section>
    <div role="button"><svg></svg></div>
    <div role="button"><svg></svg></div>
    <div role="button"><svg></svg></div>
    <div role="button" data-test="save"><svg></svg></div>
  </section>
</article></body>`;

/** jsdom has no layout, so every rect is zeros until stubbed. */
function stubRect(el, rect) {
  el.getBoundingClientRect = () => ({
    left: rect.left, top: rect.top, right: rect.right, bottom: rect.bottom,
    width: rect.right - rect.left, height: rect.bottom - rect.top, x: rect.left, y: rect.top,
  });
}

async function transformAfterScroll(ctx, host) {
  ctx.window.dispatchEvent(new ctx.window.Event("scroll"));
  return waitFor(() => (host.style.transform ? host.style.transform : null));
}

test("the button is placed beside Save when the post has an action bar", async () => {
  const ctx = await loadContentScript(ACTION_BAR_HTML);
  const host = await waitFor(() => ctx.document.querySelector("[data-carabiner-host]"));

  const container = ctx.document.querySelector("article");
  const save = ctx.document.querySelector('[data-test="save"]');
  stubRect(container, { left: 100, top: 50, right: 700, bottom: 900 });
  stubRect(save, { left: 640, top: 800, right: 664, bottom: 824 });

  const transform = await transformAfterScroll(ctx, host);
  // 640 - 24 (button) - 8 (gap) = 608; same height as the icon, so the same top.
  assert.equal(transform, "translate(608px,800px)");
});

test("a post with no action bar keeps the old top-right corner placement", async () => {
  // The fallback contract: a profile-grid thumbnail has no bar, and neither would a post
  // whose markup Instagram reshaped. The button must move, never vanish.
  const ctx = await loadContentScript(SINGLE_POST_HTML);
  const host = await waitFor(() => ctx.document.querySelector("[data-carabiner-host]"));

  const container = ctx.document.querySelector('a[href="/p/C1a2b3c4/"]');
  stubRect(container, { left: 100, top: 50, right: 700, bottom: 900 });

  const transform = await transformAfterScroll(ctx, host);
  // 700 - 24 - 8 = 668, and 50 + 8 = 58.
  assert.equal(transform, "translate(668px,58px)");
});

test("a detached Save button falls back to the corner instead of parking at 0,0", async () => {
  // React swaps these nodes out on re-render. A detached element's rect is all zeros, and
  // anchoring to it would put the button in the viewport's top-left corner — visibly wrong,
  // and on a page nowhere near the post it belongs to.
  const ctx = await loadContentScript(ACTION_BAR_HTML);
  const host = await waitFor(() => ctx.document.querySelector("[data-carabiner-host]"));

  const container = ctx.document.querySelector("article");
  stubRect(container, { left: 100, top: 50, right: 700, bottom: 900 });
  ctx.document.querySelector("section").remove();

  const transform = await transformAfterScroll(ctx, host);
  assert.equal(transform, "translate(668px,58px)");
});

/** jsdom reports scrollX/scrollY as 0 and has no real scrolling; this fakes a scrolled page. */
function stubScroll(window, { x = 0, y = 0 }) {
  Object.defineProperty(window, "scrollX", { value: x, configurable: true });
  Object.defineProperty(window, "scrollY", { value: y, configurable: true });
}

test("the button is anchored in document coordinates, so the browser scrolls it, not us", async () => {
  // User report (2026-08-19): "when i scroll, the icon is moving a bit later than the
  // actual site". Instagram scrolls on the compositor thread; a viewport-positioned
  // element only moves when this main-thread code runs, so it can only ever catch up.
  // Anchoring in document space hands the movement to the browser: the viewport rect and
  // scrollY change by the same amount, the sum does not, and there is nothing to lag.
  //
  // Without the scroll offsets this test is invisible — jsdom's scrollX/scrollY are 0, so
  // document and viewport coordinates coincide and every other placement test passes
  // either way. That is exactly the gap this pins.
  const ctx = await loadContentScript(SINGLE_POST_HTML);
  const host = await waitFor(() => ctx.document.querySelector("[data-carabiner-host]"));

  const container = ctx.document.querySelector('a[href="/p/C1a2b3c4/"]');
  stubScroll(ctx.window, { x: 40, y: 500 });
  // Viewport rect of a post 500px down a scrolled page.
  stubRect(container, { left: 100, top: 50, right: 700, bottom: 900 });

  const transform = await transformAfterScroll(ctx, host);
  // Corner placement is 700-24-8 = 668 and 50+8 = 58 in viewport space, plus the scroll
  // offsets: 668+40 = 708, 58+500 = 558.
  assert.equal(transform, "translate(708px,558px)");
});

test("the overlay and its buttons are absolutely positioned, not fixed", async () => {
  // The document-coordinate transform above is only carried by the browser's own scrolling
  // if the elements are absolute. Leave either one `fixed` and the transform is applied in
  // viewport space, which parks the button hundreds of pixels off on a scrolled page — a
  // much louder bug than the lag it replaced, so it is worth pinning both.
  const ctx = await loadContentScript(SINGLE_POST_HTML);
  const host = await waitFor(() => ctx.document.querySelector("[data-carabiner-host]"));
  const overlay = ctx.document.querySelector("carabiner-overlay");

  assert.equal(overlay.style.position, "absolute");
  assert.equal(host.style.position, "absolute");
  assert.equal(overlay.parentElement, ctx.document.documentElement, "must stay outside <body>");
});

/** A profile grid tile that lives OUTSIDE the modal, plus the modal itself. */
const GRID_WITH_MODAL_HTML = `<!doctype html><body>`
  + `<a href="/paulhumphriess/p/C1a2b3c4/">tile</a>`
  + `<div role="dialog" data-test="modal"><article>the open post</article></div>`
  + `</body>`;

test("a grid button hides when the post modal covers it — the overlay outranks Instagram's z-index", async () => {
  // User report (2026-08-19): open a profile grid, click a tile, and the grid's Carabiner
  // marks are still painted ON TOP of the post modal. 8c59ddc stopped us putting a button
  // INSIDE the dialog, but deliberately kept the tiles behind it alive ("a filter, not a
  // page-level bail-out") — and since the overlay sits on documentElement at
  // z-index 2147483000, above anything Instagram can produce, "still alive" means "drawn
  // over the modal". place() judged visibility from the container's own geometry alone,
  // which cannot see occlusion.
  const ctx = await loadContentScript(GRID_WITH_MODAL_HTML);
  const host = await waitFor(() => ctx.document.querySelector("[data-carabiner-host]"));

  const tile = ctx.document.querySelector('a[href="/paulhumphriess/p/C1a2b3c4/"]');
  const modal = ctx.document.querySelector('[data-test="modal"]');
  stubRect(tile, { left: 100, top: 600, right: 400, bottom: 900 });

  // Modal closed first: a zero-size dialog rect must NOT hide anything, or this test
  // could pass for the wrong reason (jsdom starts every rect at zeros).
  stubRect(modal, { left: 0, top: 0, right: 0, bottom: 0 });
  await transformAfterScroll(ctx, host);
  assert.equal(host.style.display, "", "tile button should be visible while no modal covers it");

  // Modal open, covering the tile.
  stubRect(modal, { left: 0, top: 0, right: 1000, bottom: 1000 });
  ctx.window.dispatchEvent(new ctx.window.Event("scroll"));
  await waitFor(() => host.style.display === "none" || null);
  assert.equal(host.style.display, "none", "tile button must hide behind the open modal");
});

/** The post modal: a [role=dialog] wrapping an <article>, plus a grid tile behind it. */
const MODAL_POST_HTML = `<!doctype html><body>`
  + `<a href="/marz.fay/p/Db1111111/">tile behind the modal</a>`
  + `<div role="dialog" data-test="modal"><article>`
  + `<a href="/p/Db2222222/">the open post</a>`
  + `<section>`
  + `<div role="button"><svg></svg></div>`
  + `<div role="button"><svg></svg></div>`
  + `<div role="button"><svg></svg></div>`
  + `<div role="button" data-test="save"><svg></svg></div>`
  + `</section>`
  + `</article></div></body>`;

/** The same modal with no action bar at all, forcing the corner fallback. */
const MODAL_NO_BAR_HTML = `<!doctype html><body>`
  + `<div role="dialog" data-test="modal"><article>`
  + `<a href="/p/Db2222222/">the open post</a>`
  + `</article></div></body>`;

test("a dialog does not occlude its OWN post — the modal keeps its button", async () => {
  // The trap this pins: yesterday's occlusion rule hides any button whose container
  // overlaps a [role=dialog]. The modal's own post is INSIDE that dialog and therefore
  // overlaps it completely, so a naive rule hides the one button the user actually asked
  // for — instantly, and with no error. A dialog occludes what is behind it, never what is
  // inside it.
  const ctx = await loadContentScript(MODAL_POST_HTML);
  await waitFor(() => ctx.document.querySelectorAll("[data-carabiner-host]").length === 2 || null);

  const tile = ctx.document.querySelector('a[href="/marz.fay/p/Db1111111/"]');
  const article = ctx.document.querySelector("article");
  const modal = ctx.document.querySelector('[data-test="modal"]');
  const save = ctx.document.querySelector('[data-test="save"]');
  const hosts = ctx.document.querySelectorAll("[data-carabiner-host]");

  stubRect(tile, { left: 100, top: 600, right: 400, bottom: 900 });
  stubRect(modal, { left: 0, top: 0, right: 1000, bottom: 1000 });
  stubRect(article, { left: 200, top: 20, right: 900, bottom: 980 });
  stubRect(save, { left: 840, top: 900, right: 864, bottom: 924 });

  ctx.window.dispatchEvent(new ctx.window.Event("scroll"));
  await waitFor(() => (hosts[1].style.transform ? hosts[1].style.transform : null));

  assert.equal(hosts[0].style.display, "none", "the grid tile behind the modal still hides");
  assert.equal(hosts[1].style.display, "", "the modal's own post must keep its button");
  // Beside Save: 840 - 24 - 8 = 808, centred on a same-height icon so the same top.
  assert.equal(hosts[1].style.transform, "translate(808px,900px)");
});

test("the modal's corner fallback drops clear of Instagram's close X", async () => {
  // 8c59ddc's bug, and why the offset exists: the modal's <article> spans nearly the whole
  // viewport, so "top-right of the container" is the top-right of the SCREEN — exactly
  // where Instagram's close X sits, and the post could no longer be closed. This path only
  // runs if the action bar is missing, but that is precisely when it must not do harm.
  const ctx = await loadContentScript(MODAL_NO_BAR_HTML);
  const host = await waitFor(() => ctx.document.querySelector("[data-carabiner-host]"));

  const article = ctx.document.querySelector("article");
  const modal = ctx.document.querySelector('[data-test="modal"]');
  stubRect(modal, { left: 0, top: 0, right: 1000, bottom: 1000 });
  stubRect(article, { left: 200, top: 20, right: 900, bottom: 980 });

  const transform = await transformAfterScroll(ctx, host);
  // Plain corner would be 900-24-8 = 868 and 20+8 = 28 — right on the X. In a dialog the
  // y drops by DIALOG_CORNER_DROP (56): 28 + 56 = 84.
  assert.equal(transform, "translate(868px,84px)");
});

test("a dialog that does not overlap a post leaves its button alone", async () => {
  // The rule is occlusion, not "a dialog exists". Instagram keeps small [role=dialog]
  // furniture around (the messages panel, the ... menu); hiding every button whenever any
  // of them is open would make the button vanish for no visible reason — this project's
  // worst failure shape, since a missing button reads as a broken extension.
  const ctx = await loadContentScript(GRID_WITH_MODAL_HTML);
  const host = await waitFor(() => ctx.document.querySelector("[data-carabiner-host]"));

  const tile = ctx.document.querySelector('a[href="/paulhumphriess/p/C1a2b3c4/"]');
  const modal = ctx.document.querySelector('[data-test="modal"]');
  stubRect(tile, { left: 100, top: 600, right: 400, bottom: 900 });
  // A panel down in the bottom-right corner, nowhere near the tile.
  stubRect(modal, { left: 1200, top: 950, right: 1500, bottom: 1050 });

  const transform = await transformAfterScroll(ctx, host);
  assert.equal(host.style.display, "", "a non-overlapping dialog must not hide the button");
  assert.equal(transform, "translate(368px,608px)");
});
