# Carousel slide index Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the in-page Instagram button grab the carousel slide the user is actually
looking at, instead of always slide 1.

**Architecture:** One new pure module, `extension/src/slideIndex.js`, answers "which slide
is showing?" from two independent sources — the page URL's `img_index`, and the active
carousel dot (`button[aria-current="step"]`) inside the post container. `content.js` calls
it **in the click handler**, so the answer is current at the moment of the click, and
appends `?img_index=N` to the permalink it sends. Nothing else changes: the button's dedup
map keeps keying on the bare permalink, so swiping never rebinds a button.

**Tech Stack:** Plain ES modules, no dependencies. Tests are `node:test` + `jsdom`, run with
`node --test` from `extension/`.

**Spec:** `docs/superpowers/specs/2026-08-17-carousel-slide-index-design.md`

## Global Constraints

- **Never throw into the page.** Every exported function in `slideIndex.js` must return
  `null` (or the input permalink) rather than throw, on any input — matching `shortcode.js`'s
  stated contract. A content script that throws breaks Instagram, not just us.
- **The page's DOM is READ-ONLY.** Query it, never write to it. Gotcha #36: writing into
  Instagram's React-hydrated tree broke Instagram itself (skeleton feeds, dead modal).
  `content.test.js` pins this invariant — do not weaken it.
- **`null` means "no opinion", never "slide 1".** The two states are different and the
  design depends on keeping them apart.
- **A known slide 1 still sends `img_index=1`.** Do not "optimise" this away; it is pinned
  by its own test. Gotcha #21's probe skip only starts at `img_index` ≥ 2, so a `1` behaves
  exactly as today's bare URL does.
- **Any new module must be added to `manifest.json`'s `web_accessible_resources`.** The test
  harness maps `chrome.runtime.getURL` to a real `file://` path, so a missing entry passes
  every test and fails only in a real browser.
- Run tests with `cd extension && node --test`. Current baseline: **64 passing**.

---

### Task 1: The pure slide-index module

**Files:**
- Create: `extension/src/slideIndex.js`
- Test: `extension/test/slideIndex.test.js`

**Interfaces:**
- Consumes: nothing. This module is standalone and imports nothing.
- Produces, relied on by Task 2:
  - `slideIndexFromSearch(search: string) => number | null`
  - `slideIndexFromContainer(element: Element) => number | null`
  - `grabUrlFor(permalink: string, opts?: { search?: string, container?: Element }) => string`

- [ ] **Step 1: Write the failing test**

Create `extension/test/slideIndex.test.js`:

```js
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { JSDOM } from "jsdom";
import { selectContainers } from "../src/containers.js";
import { slideIndexFromSearch, slideIndexFromContainer, grabUrlFor } from "../src/slideIndex.js";

const load = (name) =>
  new JSDOM(readFileSync(new URL(`./fixtures/${name}`, import.meta.url), "utf8")).window.document;

/** The one container the real captured feed fixture yields — an <article> with 4 dots. */
const feedContainer = () => selectContainers(load("feed-post.html"))[0];

test("reads the active dot out of the REAL captured feed markup", () => {
  assert.equal(slideIndexFromContainer(feedContainer()), 1);
});

test("follows the active dot when it moves — this is the bug that shipped", () => {
  const container = feedContainer();
  // Selected by label, not by position: nothing guarantees the dots are in document order.
  container.querySelector('button[aria-current="step"]').removeAttribute("aria-current");
  container.querySelector('button[aria-label="Go to slide 3"]').setAttribute("aria-current", "step");
  assert.equal(slideIndexFromContainer(container), 3);
});

test("no dots at all is no opinion, not slide 1", () => {
  const doc = new JSDOM(`<!doctype html><body><article><a href="/p/C1a2b3c4/">x</a></article>`).window.document;
  assert.equal(slideIndexFromContainer(doc.querySelector("article")), null);
});

test("two active dots is no opinion — we do not understand the page", () => {
  const doc = new JSDOM(`<!doctype html><body><article>
      <button aria-current="step" aria-label="Go to slide 1"></button>
      <button aria-current="step" aria-label="Go to slide 2"></button>
    </article>`).window.document;
  assert.equal(slideIndexFromContainer(doc.querySelector("article")), null);
});

test("grid tiles have no slide opinion", () => {
  for (const tile of selectContainers(load("grid-thumb.html"))) {
    assert.equal(slideIndexFromContainer(tile), null);
  }
});

test("never throws on junk input", () => {
  assert.equal(slideIndexFromContainer(null), null);
  assert.equal(slideIndexFromContainer(undefined), null);
  assert.equal(slideIndexFromContainer({}), null);
});

test("parses img_index out of a search string", () => {
  assert.equal(slideIndexFromSearch("?img_index=4"), 4);
  assert.equal(slideIndexFromSearch("?utm=x&img_index=12"), 12);
  assert.equal(slideIndexFromSearch("?img_index=1"), 1);
});

test("rejects img_index values that are not positive integers", () => {
  for (const s of ["?img_index=0", "?img_index=-2", "?img_index=abc", "?img_index=", "?img_index=1.5",
                   "?other=3", "", null, undefined, 7]) {
    assert.equal(slideIndexFromSearch(s), null, `expected null for ${JSON.stringify(s)}`);
  }
});

test("grabUrlFor: the address bar wins over the DOM", () => {
  assert.equal(
    grabUrlFor("https://www.instagram.com/p/C1a2b3c4/", { search: "?img_index=4", container: feedContainer() }),
    "https://www.instagram.com/p/C1a2b3c4/?img_index=4");
});

test("grabUrlFor: falls back to the container when the URL says nothing", () => {
  assert.equal(
    grabUrlFor("https://www.instagram.com/p/C1a2b3c4/", { search: "", container: feedContainer() }),
    "https://www.instagram.com/p/C1a2b3c4/?img_index=1");
});

test("grabUrlFor: knowing nothing returns the bare permalink, exactly as today", () => {
  assert.equal(grabUrlFor("https://www.instagram.com/p/C1a2b3c4/", {}),
               "https://www.instagram.com/p/C1a2b3c4/");
  assert.equal(grabUrlFor("https://www.instagram.com/p/C1a2b3c4/"),
               "https://www.instagram.com/p/C1a2b3c4/");
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd extension && node --test test/slideIndex.test.js`
Expected: FAIL — `Cannot find module .../src/slideIndex.js`.

- [ ] **Step 3: Write the implementation**

Create `extension/src/slideIndex.js`:

```js
// Which carousel slide is the user actually looking at?
//
// Without this, the button always grabbed slide 1: shortcode.js canonicalises every match
// to a bare `https://www.instagram.com/p/CODE/`, and per gotcha #15 the app reads a missing
// `img_index` as slide 1. So "This slide" on a feed carousel silently saved the wrong file
// and still reported success — found 2026-08-17 by a user test, not by any test in here.
//
// Two independent sources, deliberately ordered (see the design doc):
//   1. the page URL's `img_index` — what the app has always trusted, and what the hotkey
//      path feeds it; authoritative wherever it exists (permalink pages).
//   2. the active carousel dot — the only source on a feed, where the URL is just
//      `instagram.com/`. Instagram marks it semantically, `aria-current="step"` on a
//      `<button aria-label="Go to slide N">`, and the dots sit INSIDE the post container
//      the button is already keyed on (verified against the real captured fixture).
//
// Same contract as shortcode.js: NEVER throws, and `null` means "no opinion" — never
// "slide 1". Collapsing those two states is exactly the bug this module exists to fix.
//
// Callers must resolve at CLICK time, not attach time — see content.js.

const SLIDE_LABEL = /slide\s+(\d+)/i;

/** `null` unless `raw` is a positive integer. Deliberately strict: "0", "-2", "1.5" are not slides. */
function positiveInt(raw) {
  if (!/^\d+$/.test(String(raw).trim())) return null;
  const n = Number(raw);
  return Number.isSafeInteger(n) && n >= 1 ? n : null;
}

/**
 * @param {string} search a `location.search`-shaped string, e.g. "?img_index=3"
 * @returns {number|null}
 */
export function slideIndexFromSearch(search) {
  if (typeof search !== "string" || search === "") return null;
  // No decodeURIComponent: a slide index is digits, and decodeURIComponent THROWS on
  // malformed input ("%"), which would violate this module's never-throw contract for
  // nothing in return.
  const match = /[?&]img_index=([^&]*)/.exec(search);
  return match ? positiveInt(match[1]) : null;
}

/**
 * @param {Element} element the post container
 * @returns {number|null} `null` unless EXACTLY one dot is active — zero means "not a
 *   carousel, or Instagram changed the markup", more than one means we do not understand
 *   this page well enough to answer, and guessing is how the original bug felt to a user.
 */
export function slideIndexFromContainer(element) {
  if (!element || typeof element.querySelectorAll !== "function") return null;
  const active = element.querySelectorAll('button[aria-current="step"]');
  if (active.length !== 1) return null;
  const match = SLIDE_LABEL.exec(active[0].getAttribute("aria-label") || "");
  return match ? positiveInt(match[1]) : null;
}

/**
 * @param {string} permalink the canonical, query-less form from shortcode.js
 * @param {{search?: string, container?: Element}} [sources]
 * @returns {string} the permalink, with `?img_index=N` appended when a slide is known.
 */
export function grabUrlFor(permalink, sources = {}) {
  if (typeof permalink !== "string" || permalink === "") return permalink;
  const fromSearch = slideIndexFromSearch(sources.search);
  const index = fromSearch === null ? slideIndexFromContainer(sources.container) : fromSearch;
  // Appends even when the answer is 1 — "we know it is slide 1" and "we have no idea" are
  // different states, and the permalink is always query-less here, so this is a plain
  // append and never a query-string merge.
  return index === null ? permalink : `${permalink}?img_index=${index}`;
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd extension && node --test test/slideIndex.test.js`
Expected: PASS, 11 tests.

- [ ] **Step 5: Run the whole suite for regressions**

Run: `cd extension && node --test`
Expected: PASS, 75 tests (64 baseline + 11).

- [ ] **Step 6: Commit**

```bash
git add extension/src/slideIndex.js extension/test/slideIndex.test.js
git commit -m "feat: read the active carousel slide from the page

Pure module, same never-throw contract as shortcode.js. null means 'no
opinion', never slide 1 — collapsing those is the bug this fixes."
```

---

### Task 2: Resolve at click time and send it

**Files:**
- Modify: `extension/src/content.js` (the module import block at lines 20-24, and the click
  handler's `chrome.runtime.sendMessage` call at line ~185)
- Modify: `extension/manifest.json` (the `web_accessible_resources` resources array, line 24)
- Modify: `extension/test/content.test.js` (`loadContentScript` needs an optional page URL)

**Interfaces:**
- Consumes from Task 1: `grabUrlFor(permalink, { search, container })`.
- Produces: nothing further depends on this task.

- [ ] **Step 1: Write the failing tests**

First, `loadContentScript` hardcodes the page URL, so precedence cannot be tested. In
`extension/test/content.test.js`, change its signature and the `JSDOM` construction:

```js
async function loadContentScript(html, { url = "https://www.instagram.com/" } = {}) {
  previousWindow?.close();
  const dom = new JSDOM(html, { url, pretendToBeVisual: true });
```

Then append these tests to the same file:

```js
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

test("on a permalink page the address bar wins over the dots", async () => {
  const ctx = await loadContentScript(FEED_CAROUSEL_HTML,
    { url: "https://www.instagram.com/p/C1a2b3c4/?img_index=4" });
  const host = await waitFor(() => ctx.document.querySelector("[data-carabiner-host]"));
  ctx.shadowOf(host).querySelector("button").click();

  assert.match(ctx.sentMessages[0].url, /\?img_index=4$/);
  ctx.deliver({ type: "done", id: ctx.sentMessages[0].id, result: "ok" });
});

test("swiping does not rebind the button — the slide index is not baked into the dedup key", async () => {
  const ctx = await loadContentScript(FEED_CAROUSEL_HTML);
  const host = await waitFor(() => ctx.document.querySelector("[data-carabiner-host]"));

  ctx.document.querySelector('button[aria-current="step"]').removeAttribute("aria-current");
  ctx.document.querySelector('button[aria-label="Go to slide 3"]').setAttribute("aria-current", "step");
  // That DOM change triggers content.js's own MutationObserver-driven rescan; give it a
  // few frames to run before counting.
  await new Promise((r) => setTimeout(r, 100));

  assert.equal(ctx.document.querySelectorAll("[data-carabiner-host]").length, 1,
               "a swipe must not create a second button");
  assert.equal(ctx.document.querySelector("[data-carabiner-host]"), host,
               "and must not replace the existing one");
});
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd extension && node --test test/content.test.js`
Expected: FAIL — the first three fail on the URL assertion, reporting a bare
`https://www.instagram.com/p/CODE/` with no `?img_index`.

- [ ] **Step 3: Add the module to the web-accessible allowlist**

In `extension/manifest.json`, add `"src/slideIndex.js"` to the resources array:

```json
      "resources": ["src/shortcode.js", "src/ring.js", "src/containers.js", "src/grabTracker.js", "src/slideIndex.js"],
```

Without this the dynamic `import()` is blocked in a real browser and the button silently
stops working — while every test here still passes, because the harness resolves
`chrome.runtime.getURL` to a `file://` path that ignores the manifest.

- [ ] **Step 4: Import the module in content.js**

In `extension/src/content.js`, extend the declaration on line 20 and the import block:

```js
  let permalinkFor, selectContainers, createGrabTracker, grabUrlFor;
  try {
    ({ permalinkFor } = await import(chrome.runtime.getURL("src/shortcode.js")));
    ({ selectContainers } = await import(chrome.runtime.getURL("src/containers.js")));
    ({ createGrabTracker } = await import(chrome.runtime.getURL("src/grabTracker.js")));
    ({ grabUrlFor } = await import(chrome.runtime.getURL("src/slideIndex.js")));
    console.debug("[carabiner] modules loaded");
```

- [ ] **Step 5: Resolve at click time**

In the click handler, replace the `sendMessage` call's `url` with the resolved value.
Change:

```js
        chrome.runtime.sendMessage({ type: "grab", id, url, browser: detectBrowser() }, (reply) => {
```

to:

```js
        // Resolved HERE, not in makeButton: `url` is closed over at attach time and the
        // buttons map rebinds only when it changes, so a slide index computed at attach
        // would be stale the moment the user swipes — and baking it into `url` would
        // destroy and recreate the button on every swipe. Reading the container is a
        // query, never a write (gotcha #36).
        const grabUrl = grabUrlFor(url, { search: location.search, container });
        // Breadcrumb for the one case that silently reverts to the old behaviour: a post
        // that HAS carousel dots but no single readable active one, i.e. Instagram changed
        // the markup. Deliberately not logged for ordinary single posts, which have no
        // dots and for which "no slide index" is simply correct.
        if (grabUrl === url && container.querySelector('button[aria-label^="Go to slide"]')) {
          console.debug("[carabiner] carousel with no readable active slide — grabbing slide 1");
        }
        chrome.runtime.sendMessage({ type: "grab", id, url: grabUrl, browser: detectBrowser() }, (reply) => {
```

Note `container` is already in scope — `makeButton(url, container)` takes it as its second
parameter.

- [ ] **Step 6: Run the tests to verify they pass**

Run: `cd extension && node --test test/content.test.js`
Expected: PASS.

- [ ] **Step 7: Mutation-check the guard — actually revert it and look**

Gotcha #34's rule: a regression test you did not watch fail proves nothing. Temporarily
move the resolution back to attach time by editing `makeButton`'s opening line to
`const attachUrl = grabUrlFor(url, { search: location.search, container });` and sending
`attachUrl`, then run `cd extension && node --test test/content.test.js`.

Expected: the "resolution is at CLICK time" test FAILS (it reports `img_index=1` where 3
was expected). If it passes, the test has no teeth — fix the test before restoring the
implementation. Then revert the mutation and re-run to confirm green again.

- [ ] **Step 8: Run the whole suite**

Run: `cd extension && node --test`
Expected: PASS, 79 tests (75 after Task 1 + 4).

- [ ] **Step 9: Commit**

```bash
git add extension/src/content.js extension/manifest.json extension/test/content.test.js
git commit -m "fix: the button grabs the slide you are looking at

Resolved at click time — url is closed over at attach and the dedup map
rebinds on url change, so anything computed at attach would be stale or
would recreate the button on every swipe. Mutation-checked."
```

---

## Verification in a real browser

The tests cannot see the manifest, so finish with one real check — this is the step that
would catch a missing `web_accessible_resources` entry:

1. `cd extension && ./build.sh`, then reload the extension in `chrome://extensions`.
2. Open a **fresh** Instagram tab (gotcha #36: an old tab runs an orphaned content script
   and will report on old code).
3. On a feed carousel, swipe to slide 2 or 3, click the button, answer **"This slide"**.
4. Confirm the file that lands in `~/Downloads` is that slide — check the `_sN` suffix in
   the filename, and open it. Snapshot-diff rather than trusting timestamps: gallery-dl
   preserves Instagram's original mtime, so `ls -lt` will not show a fresh image.

```bash
ls -1 ~/Downloads > /tmp/before.txt   # …click the button…
ls -1 ~/Downloads | diff /tmp/before.txt - | grep '^>'
```
