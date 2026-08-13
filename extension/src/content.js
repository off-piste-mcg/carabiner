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
  let permalinkFor, selectContainers, createGrabTracker;
  try {
    ({ permalinkFor } = await import(chrome.runtime.getURL("src/shortcode.js")));
    ({ selectContainers } = await import(chrome.runtime.getURL("src/containers.js")));
    ({ createGrabTracker } = await import(chrome.runtime.getURL("src/grabTracker.js")));
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
  // The watchdog's "we've lost track of this grab" glyph (fix round 1, Finding 6) —
  // deliberately distinct from both TICK and CROSS, and not a claim of failure: what's
  // confirmed lost is the connection to the app, not necessarily the grab itself. Fix
  // round 2, Finding 1 made this recoverable: a late progress/done message re-adopts the
  // button out of this state (see grabTracker.js), so amber is "no news yet", never final.
  const INTERRUPTED = `<path d="M12 8v5M12 16h.01" stroke="#fff" stroke-width="2.5" stroke-linecap="round"/>`;

  // Fix round 2, Finding 1: reconsidering the fix-round-1 30s constant now that amber is
  // recoverable rather than terminal. The reviewer traced three ordinary paths — none of
  // them a dead worker — where 30s of silence is routine, not exceptional: carabiner's
  // libx264 encode emits one `convert` marker and then nothing until it finishes
  // (gotcha #21 measures 12.3s of silence for a 45s reel, i.e. ~0.27s of encode time per
  // second of source video — a 2-3 minute video comfortably exceeds 30s on that rate
  // alone); gallery-dl emits no progress at all after its single `download` marker; and
  // `prompt` is handled separately below (suspended, not just given a bigger number).
  // Since a fired watchdog is no longer a wrong verdict — only a temporary, self-correcting
  // status — this can afford real headroom instead of trying to bound the encode case
  // exactly. At the gotcha #21 rate, 90s of silence corresponds to roughly 90/0.27 ≈ 330s
  // (5.5 minutes) of source video, which comfortably covers everything this tool targets
  // (Instagram reels/posts, not arbitrary long-form video) while still catching a
  // genuinely dead connection well before a user gives up and closes the tab.
  const WATCHDOG_MS = 90000;

  const tracker = createGrabTracker({ watchdogMs: WATCHDOG_MS });

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
    const paint = (symbol, colour) => {
      ring.classList.add("hidden");
      glyph.classList.remove("hidden");
      glyph.innerHTML = symbol;
      button.style.background = colour;
    };
    // A second grab on the same button must not inherit whatever the previous one left
    // behind — a stuck red/green/amber inline background with nothing to clear it before
    // the ring drew on top. reset() puts the button back to its true rest state.
    const reset = () => paint(ARROW, "");

    // Maps the tracker's semantic outcome to what the button actually shows. Fix round 2
    // minor: `cancelled` used to call the old settle("", ...) directly, which left a
    // glyph-less black circle — a deliberate act deserves the real rest state (the
    // arrow), not a blank one, so it now goes through reset().
    const settle = (outcome) => {
      switch (outcome) {
        case "ok": paint(TICK, "rgba(40,160,80,.9)"); break;
        case "cancelled": reset(); break;
        case "interrupted": paint(INTERRUPTED, "rgba(180,130,30,.9)"); break;
        case "error":
        default: paint(CROSS, "rgba(200,40,40,.9)"); break;
      }
    };

    button.addEventListener("click", (e) => {
      e.preventDefault();
      e.stopPropagation();          // do not let the click open the post
      reset();
      setRing(0.02);                // immediate acknowledgement, before anything downloads
      const id = nextId();
      tracker.start(id, { setRing, settle });
      try {
        chrome.runtime.sendMessage({ type: "grab", id, url, browser: detectBrowser() }, (reply) => {
          // Fix round 1, Finding 3: a worker that failed to register at all — the exact
          // Safari importScripts risk this extension takes on — used to leave this
          // callback firing with `reply` undefined and nothing checked, so the button
          // spun forever. chrome.runtime.lastError is what Chrome sets in that exact case
          // ("Receiving end does not exist"); a missing `accepted` covers everything else.
          if (chrome.runtime.lastError || !reply?.accepted) {
            tracker.abort(id);
            settle("error");
          }
        });
      } catch (_) {
        // Fix round 2 minor: chrome.runtime.sendMessage throws SYNCHRONOUSLY, not just
        // rejects, when the content script has been orphaned (its extension context
        // invalidated by a reload) — routine during development, and this file's own
        // rule is "nothing may throw into the page". Caught here rather than left to
        // become an uncaught exception in the click handler.
        tracker.abort(id);
        settle("error");
      }
    });

    return host;
  }

  function detectBrowser() {
    return navigator.userAgent.includes("Safari") && !navigator.userAgent.includes("Chrome")
      ? "safari" : "chrome";
  }

  // Every message from the worker carries the id of the grab it belongs to (fix round 1,
  // Finding 2) — routing and the watchdog itself both live in grabTracker.js now, so this
  // listener is just wiring.
  chrome.runtime.onMessage.addListener((msg) => {
    tracker.receive(msg);
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
