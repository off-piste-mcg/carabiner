// A classic (non-module) content script — deliberately NOT injected via a page-context
// <script type="module"> tag. That trick (this file's first draft used it, via a
// since-removed loader.js) puts the code in the PAGE's own main-world JS context, which
// does escape the "content scripts can't use static import" limit, but at a cost that
// breaks the whole feature: chrome.* APIs are bound only into the isolated world a
// content script runs in, not into the page's own globals, so chrome.runtime.sendMessage
// and chrome.runtime.onMessage below would be undefined and every button click or
// incoming progress message would throw. The documented, supported way to use ES modules
// from a content script without leaving the isolated world is a dynamic import() of a
// web-accessible resource — see https://developer.chrome.com/docs/extensions/develop/concepts/content-scripts#modules.
// That keeps chrome.* available, at the cost of needing an async IIFE (top-level await
// needs a real module, and a content script can't be one while using static import).
(async () => {
  let permalinkFor, ringFractionForProgress, outcomeFor, selectContainers;
  try {
    ({ permalinkFor } = await import(chrome.runtime.getURL("src/shortcode.js")));
    ({ ringFractionForProgress, outcomeFor } = await import(chrome.runtime.getURL("src/ring.js")));
    ({ selectContainers } = await import(chrome.runtime.getURL("src/containers.js")));
  } catch (_) {
    return; // no modules, no button — never throw into the page.
  }

  const SIZE = 28;
  // Marks the button's own host element, not the post container (fix round 1, Finding
  // 5). A one-time mark on the container survives even after a re-render (React et al.)
  // silently drops our host node as an unrecognised child, permanently hiding the button
  // on a post that still looks "already handled". Checking for a LIVE child with this
  // mark instead means a removed button gets re-attached on the next scan.
  const HOST_MARK = "data-carabiner-host";

  const ARROW = `<path d="M12 3v12m0 0 4-4m-4 4-4-4M4 19h16" stroke="#fff" stroke-width="2" stroke-linecap="round"/>`;
  const TICK = `<path d="M5 13l4 4L19 7" stroke="#fff" stroke-width="2.5" stroke-linecap="round" fill="none"/>`;
  const CROSS = `<path d="M6 6l12 12M18 6L6 18" stroke="#fff" stroke-width="2.5" stroke-linecap="round"/>`;
  // The watchdog's "we lost track of this grab" glyph (fix round 1, Finding 6) —
  // deliberately distinct from both TICK and CROSS, and not a claim of failure: what's
  // confirmed lost is the connection to the app, not necessarily the grab itself.
  const INTERRUPTED = `<path d="M12 8v5M12 16h.01" stroke="#fff" stroke-width="2.5" stroke-linecap="round"/>`;

  // One entry per in-flight grab, keyed by a per-click id — NOT a single "most recently
  // clicked button" pointer (fix round 1, Finding 2). A single `active` owner broke as
  // soon as two buttons could exist on one post (Finding 1 made that trivially reachable:
  // click A, then click B before A's stream ends, and A's real terminal line arrived
  // after `active` had already moved to B and been cleared, so A spun forever). Each grab
  // now owns its own {setRing, settle, reset}, addressed by the id the worker echoes back
  // on every message for it.
  const grabs = new Map();
  // Per-grab "we've heard nothing in a while" timers (fix round 1, Finding 6).
  const watchdogs = new Map();
  // Comfortably longer than the worst normal silent gap between progress lines we know
  // about (~12s for a full libx264 re-encode with no intervening progress marker — see
  // CLAUDE.md gotcha #21), and, conveniently, in the same neighborhood as Safari's
  // measured ~30s service-worker idle-kill window (this review's Finding 6) — so a dead
  // worker and this client-side "give up" tend to surface together instead of one
  // silently lagging the other by minutes. This is NOT a hard failure: the grab may well
  // have already succeeded by the time it fires (the app's own banner is authoritative),
  // which is why it settles into the distinct amber "interrupted" state, not the red one.
  const WATCHDOG_MS = 30000;

  function armWatchdog(id) {
    clearWatchdog(id);
    watchdogs.set(id, setTimeout(() => {
      const owner = grabs.get(id);
      if (!owner) return; // already settled through the normal path
      grabs.delete(id);
      watchdogs.delete(id);
      owner.settle(INTERRUPTED, "rgba(180,130,30,.9)");
    }, WATCHDOG_MS));
  }
  function clearWatchdog(id) {
    const t = watchdogs.get(id);
    if (t !== undefined) {
      clearTimeout(t);
      watchdogs.delete(id);
    }
  }
  function nextId() {
    return (crypto.randomUUID && crypto.randomUUID())
      || `${Date.now()}-${Math.random().toString(36).slice(2)}`;
  }

  // Shadow DOM so Instagram's CSS cannot reach our button and ours cannot leak into the
  // page. Without it, one Instagram style change silently reshapes the button.
  function makeButton(url) {
    const host = document.createElement("div");
    host.style.cssText = "position:absolute;top:8px;right:8px;z-index:9999;";
    const root = host.attachShadow({ mode: "closed" });
    root.innerHTML = `
      <style>
        button { width:${SIZE}px; height:${SIZE}px; border:0; border-radius:50%;
                 background:rgba(0,0,0,.65); cursor:pointer; display:grid;
                 place-items:center; padding:0; backdrop-filter:blur(4px); }
        button:hover { background:rgba(45,91,255,.9); }
        svg { width:16px; height:16px; }
        .track { stroke:rgba(255,255,255,.25); }
        .fill  { stroke:#fff; stroke-linecap:round;
                 transform:rotate(-90deg); transform-origin:center;
                 transition:stroke-dasharray .2s linear; }
        .hidden { display:none; }
      </style>
      <button title="Save with Carabiner">
        <svg viewBox="0 0 24 24" fill="none" class="glyph">${ARROW}</svg>
        <svg viewBox="0 0 24 24" fill="none" class="ring hidden">
          <circle class="track" cx="12" cy="12" r="9" stroke-width="2.5"/>
          <circle class="fill"  cx="12" cy="12" r="9" stroke-width="2.5" stroke-dasharray="0 57"/>
        </svg>
      </button>`;
    const button = root.querySelector("button");
    const glyph = root.querySelector(".glyph");
    const ring = root.querySelector(".ring");
    const fill = root.querySelector(".fill");

    const setRing = (fraction) => {
      glyph.classList.add("hidden");
      ring.classList.remove("hidden");
      fill.setAttribute("stroke-dasharray", `${(57 * fraction).toFixed(1)} 57`);
    };
    const settle = (symbol, colour) => {
      ring.classList.add("hidden");
      glyph.classList.remove("hidden");
      glyph.innerHTML = symbol;
      button.style.background = colour;
    };
    // Fix round 1, minor: a second grab on the same button used to inherit whatever the
    // previous one left behind — `cancelled`'s blank glyph (settle("", ...) never
    // restored the arrow), or a stuck red/green inline background with nothing to clear
    // it before the ring drew on top. reset() puts the button back to its true rest
    // state before a new grab claims it.
    const reset = () => {
      ring.classList.add("hidden");
      glyph.classList.remove("hidden");
      glyph.innerHTML = ARROW;
      button.style.background = "";
    };

    button.addEventListener("click", (e) => {
      e.preventDefault();
      e.stopPropagation();          // do not let the click open the post
      reset();
      setRing(0.02);                // immediate acknowledgement, before anything downloads
      const id = nextId();
      grabs.set(id, { setRing, settle, reset });
      armWatchdog(id);
      chrome.runtime.sendMessage({ type: "grab", id, url, browser: detectBrowser() }, (reply) => {
        // Fix round 1, Finding 3: a worker that failed to register at all — the exact
        // Safari importScripts risk this extension takes on — used to leave this
        // callback firing with `reply` undefined and nothing checked, so the button spun
        // forever. chrome.runtime.lastError is what Chrome sets in that exact case
        // ("Receiving end does not exist"); a missing `accepted` covers everything else.
        if (chrome.runtime.lastError || !reply?.accepted) {
          clearWatchdog(id);
          grabs.delete(id);
          settle(CROSS, "rgba(200,40,40,.9)");
        }
      });
    });

    return host;
  }

  function detectBrowser() {
    return navigator.userAgent.includes("Safari") && !navigator.userAgent.includes("Chrome")
      ? "safari" : "chrome";
  }

  // Every message from the worker carries the id of the grab it belongs to (fix round 1,
  // Finding 2) — that id, not "whichever button was clicked most recently", decides which
  // button reacts.
  chrome.runtime.onMessage.addListener((msg) => {
    if (msg == null || msg.id == null) return;
    const owner = grabs.get(msg.id);
    if (!owner) return; // already settled — e.g. the watchdog already gave up on it
    if (msg.type === "progress") {
      armWatchdog(msg.id); // any real message resets the "we lost track" clock
      // The ring means "downloading" — the same rule the menu-bar ring follows. Stages
      // before real work (probe, prompt) must not advance it. ringFractionForProgress
      // (extension/src/ring.js) is the single, unit-tested place that rule lives.
      const fraction = ringFractionForProgress(msg);
      if (fraction !== null) owner.setRing(fraction);
    } else if (msg.type === "done") {
      clearWatchdog(msg.id);
      grabs.delete(msg.id);
      const outcome = outcomeFor(msg);
      if (outcome === "ok") owner.settle(TICK, "rgba(40,160,80,.9)");
      // Cancel is a deliberate act, not a failure — no error state for it, just back to rest.
      else if (outcome === "cancelled") owner.settle("", "rgba(0,0,0,.65)");
      else owner.settle(CROSS, "rgba(200,40,40,.9)");
    }
  });

  function attach(container) {
    // A live-child check, not a one-time mark on the container (fix round 1, Finding 5)
    // — see HOST_MARK's own comment for why.
    if (container.querySelector(`:scope > [${HOST_MARK}]`)) return;
    const url = permalinkFor(container);
    if (!url) return;                       // no shortcode, no button. Never throw.
    if (getComputedStyle(container).position === "static") container.style.position = "relative";
    const host = makeButton(url);
    host.setAttribute(HOST_MARK, "1");
    container.appendChild(host);
  }

  function scan() {
    // selectContainers (extension/src/containers.js) dedupes an <article> against the
    // permalink anchor nested inside it — fix round 1, Finding 1, which was two buttons
    // on one post, DEMONSTRATED against this repo's own fixtures.
    for (const el of selectContainers(document)) {
      try { attach(el); } catch (_) { /* one bad node must not kill the observer */ }
    }
  }

  // Coalesced to at most one scan per animation frame (fix round 1, Finding 4).
  // Instagram's feed mutates constantly, and scan() itself does a whole-document
  // querySelectorAll plus a getComputedStyle per candidate — running it synchronously on
  // every mutation batch was wasteful on its own, and self-amplifying: `attach`'s own
  // `container.appendChild(host)` is itself a childList mutation that would otherwise
  // schedule yet another full scan.
  let scanScheduled = false;
  function scheduleScan() {
    if (scanScheduled) return;
    scanScheduled = true;
    requestAnimationFrame(() => {
      scanScheduled = false;
      scan();
    });
  }

  new MutationObserver(scheduleScan).observe(document.body, { childList: true, subtree: true });
  scheduleScan();
})();
