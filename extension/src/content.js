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
  let permalinkFor, ringFractionForProgress, outcomeFor;
  try {
    ({ permalinkFor } = await import(chrome.runtime.getURL("src/shortcode.js")));
    ({ ringFractionForProgress, outcomeFor } = await import(chrome.runtime.getURL("src/ring.js")));
  } catch (_) {
    return; // no modules, no button — never throw into the page.
  }

  const MARK = "data-carabiner";
  const SIZE = 28;

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
        <svg viewBox="0 0 24 24" fill="none" class="glyph">
          <path d="M12 3v12m0 0 4-4m-4 4-4-4M4 19h16" stroke="#fff" stroke-width="2" stroke-linecap="round"/>
        </svg>
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

    button.addEventListener("click", (e) => {
      e.preventDefault();
      e.stopPropagation();          // do not let the click open the post
      setRing(0.02);                // immediate acknowledgement, before anything downloads
      chrome.runtime.sendMessage({ type: "grab", url, browser: detectBrowser() }, (reply) => {
        if (reply?.error) settle(CROSS, "rgba(200,40,40,.9)");
      });
    });

    host.__carabiner = { setRing, settle, url };
    return host;
  }

  const TICK = `<path d="M5 13l4 4L19 7" stroke="#fff" stroke-width="2.5" stroke-linecap="round" fill="none"/>`;
  const CROSS = `<path d="M6 6l12 12M18 6L6 18" stroke="#fff" stroke-width="2.5" stroke-linecap="round"/>`;

  function detectBrowser() {
    return navigator.userAgent.includes("Safari") && !navigator.userAgent.includes("Chrome")
      ? "safari" : "chrome";
  }

  // Progress is broadcast to the tab, and the most recently clicked button owns it. Only
  // one grab runs at a time (the app returns 409 otherwise), so a single owner is correct.
  let active = null;

  chrome.runtime.onMessage.addListener((msg) => {
    if (!active) return;
    if (msg.type === "progress") {
      // The ring means "downloading" — the same rule the menu-bar ring follows. Stages
      // before real work (probe, prompt) must not advance it. ringFractionForProgress
      // (extension/src/ring.js) is the single, unit-tested place that rule lives.
      const fraction = ringFractionForProgress(msg);
      if (fraction !== null) active.__carabiner.setRing(fraction);
    } else if (msg.type === "done") {
      const outcome = outcomeFor(msg);
      if (outcome === "ok") active.__carabiner.settle(TICK, "rgba(40,160,80,.9)");
      // Cancel is a deliberate act, not a failure — no error state for it, just back to rest.
      else if (outcome === "cancelled") active.__carabiner.settle("", "rgba(0,0,0,.65)");
      else active.__carabiner.settle(CROSS, "rgba(200,40,40,.9)");
      active = null;
    }
  });

  function attach(container) {
    if (container.hasAttribute(MARK)) return;
    const url = permalinkFor(container);
    if (!url) return;                       // no shortcode, no button. Never throw.
    container.setAttribute(MARK, "1");
    if (getComputedStyle(container).position === "static") container.style.position = "relative";
    const host = makeButton(url);
    host.addEventListener("click", () => { active = host; }, true);
    container.appendChild(host);
  }

  function scan() {
    for (const el of document.querySelectorAll("article, a[href^='/p/'], a[href^='/reel/']")) {
      try { attach(el); } catch (_) { /* one bad node must not kill the observer */ }
    }
  }

  new MutationObserver(scan).observe(document.body, { childList: true, subtree: true });
  scan();
})();
