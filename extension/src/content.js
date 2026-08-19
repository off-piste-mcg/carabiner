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
  // console.debug breadcrumbs, deliberately kept: the import failure below is silent by
  // design ("never throw into the page"), and 2026-08-17 proved that a silent failure
  // here is indistinguishable from "not injected at all" from outside the extension —
  // an afternoon of debugging that two debug lines would have answered in ten seconds.
  // debug-level, so they are invisible unless the console is set to Verbose.
  console.debug("[carabiner] content script injected");
  let permalinkFor, permalinkFromHref, selectContainers, createGrabTracker, grabUrlFor,
      findSaveButton, saveAnchorPosition;
  try {
    ({ permalinkFor, permalinkFromHref } = await import(chrome.runtime.getURL("src/shortcode.js")));
    ({ selectContainers } = await import(chrome.runtime.getURL("src/containers.js")));
    ({ createGrabTracker } = await import(chrome.runtime.getURL("src/grabTracker.js")));
    ({ grabUrlFor } = await import(chrome.runtime.getURL("src/slideIndex.js")));
    ({ findSaveButton, saveAnchorPosition } = await import(chrome.runtime.getURL("src/actionBar.js")));
    console.debug("[carabiner] modules loaded");
  } catch (e) {
    console.debug("[carabiner] module import failed:", e && e.message);
    return; // no modules, no button — never throw into the page.
  }

  // 24, matching the size of Instagram's own action-bar icons, because the button now sits
  // in that row beside Save rather than floating in the post's corner (2026-08-19). This is
  // a deliberate trade against the note that used to live here: the rest glyph is the
  // Carabiner mark, fine-line art that fills in solid below roughly 24px, and 32 was chosen
  // to keep it from reading as a smudge. 24 sits exactly on that boundary — it buys
  // belonging in the row at the cost of the mark's last legibility. If it ever reads as a
  // blob, the fix is a simplified mark at this size, NOT a larger button, which would look
  // like an add-on wedged into Instagram's UI. The ring shares this size.
  const SIZE = 24;
  // Space between our button and the Save icon it sits beside.
  const ANCHOR_GAP = 8;
  // Kept on each overlay host purely as an identifying mark (tests and debugging query
  // it). Dedup no longer reads it — that is the `buttons` Map's job now.
  const HOST_MARK = "data-carabiner-host";

  // The rest state is the Carabiner mark, not a generic download arrow — same silhouette
  // as the menu-bar status item, so the button is recognisably ours on a page full of
  // other people's chrome. Source: app/Carabiner/Assets.xcassets/StatusIcon.imageset/
  // carabiner-status.svg, whose own viewBox is "103 51 306 409". paint() swaps innerHTML
  // inside one fixed `viewBox="0 0 24 24"` svg shared with TICK/CROSS/INTERRUPTED, so the
  // mark cannot bring its own viewBox and is fitted with a transform instead: scale
  // 20/409 ≈ 0.0489 (20 of the 24 units tall, matching the other glyphs' optical size),
  // then translated to centre it — x: (24 - 306*s)/2 - 103*s, y: (24 - 20)/2 - 51*s.
  // It is a fill, where the other glyphs are strokes; both render white on the same
  // circle, and `fill="none"` on the parent svg is overridden per-path as before.
  const MARK = `<g transform="translate(-0.52,-0.49) scale(0.0489)"><path d="M201.781 447.619C191.821 461.88 174.886 462.367 158.985 456.399C139.94 449.254 123.307 436.299 112.687 418.982C107.119 409.887 104.751 399.198 107.392 389.041C109.171 382.197 113.362 376.487 117.524 371.05C122.92 363.991 123.063 355.569 117.423 348.611C111.123 340.835 106.129 332.127 104.105 322.098C101.091 307.192 104.392 292.07 112.558 279.359L126.335 260.077C130.067 254.854 132.564 249.388 132.607 242.832L132.679 229.059C132.765 213.033 136.41 197.955 145.179 184.612C155.985 168.199 173.795 153.695 193.127 149.922C209.042 146.823 220.294 132.878 224.915 117.67C228.173 106.938 233.698 97.5269 241.505 89.5501C246.873 84.0839 251.393 85.5473 252.556 81.8601L265.156 77.513C265.788 75.8201 267.036 74.6724 268.586 74.0124L273.911 71.7313C278.675 69.694 283.957 68.0011 289.008 67.0255C299.14 65.06 306.345 60.2968 314.697 58.9626L320.811 57.987C322.763 57.6713 324.069 57.5135 325.705 58.8908L331.574 56.9253L336.382 55.6628L347.849 52.6069C365.114 48.0016 383.139 53.3386 394.778 66.8533C398.768 71.4874 401.207 76.8818 402.958 82.764C405.57 91.6017 404.537 100.726 399.686 108.603L384.23 133.738C377.37 144.9 367.395 157.468 367.812 171.341C367.898 174.455 371.428 178.443 374.758 176.305C380.398 172.676 388.248 150.338 391.692 140.496C393.084 136.536 394.778 132.82 397.045 129.334C399.586 125.432 404.135 122.878 407.034 124.485C415.2 129.018 396.069 165.359 390.386 176.994C384.689 188.658 379.565 200.021 375.332 212.23C372.605 220.092 371.227 227.61 371.701 235.96C372.404 248.298 367.324 259.905 357.909 267.695C356.173 269.13 355.656 271.095 356.23 273.233C359.918 287.092 357.507 299.645 345.452 307.608C331 317.163 324.226 340.993 322.562 358.381C319.978 385.368 299.556 407.118 272.346 409.901C256.789 411.493 245.94 402.756 232.048 411.766C225.561 415.97 220.193 421.321 215.701 427.748L201.824 447.619H201.781ZM227.154 167.152C231.057 162.002 234.975 157.583 239.553 153.781C249.126 145.833 255.412 158.616 261.08 155.373C273.25 148.415 288.578 125.432 298.294 112.605L309.287 98.1008C313.965 91.9173 324.27 83.1083 328.446 86.5372C334.014 91.1139 321.873 110.08 314.668 117.283L290.917 140.969L275.618 156.005C272.648 158.931 270.265 163.924 272.576 165.89C273.236 166.449 275.518 166.88 276.379 166.478L285.004 162.518C286.324 161.916 288.262 161.844 289.109 162.489C292.252 164.871 289.798 171.413 285.463 176.162L271.973 190.911C263.836 199.806 264.123 218.528 264.783 231.684C264.898 233.951 266.577 236.634 268.127 237.265C270.265 238.14 273.25 237.107 274.829 235.902C279.981 231.971 281.215 226.849 279.077 220.967C277.068 215.458 278.661 209.805 283.497 206.52C293.572 199.676 301.609 191.327 308.569 181.341L327.513 154.211C334.272 144.527 343.099 137.368 354.264 133.394C358.928 131.73 362.444 128.373 365.07 124.198C370.395 115.762 376.236 108.101 382.35 100.325C386.339 95.2458 386.885 89.1196 383.11 83.9117C374.083 71.473 358.512 66.5664 344.878 73.0655L339.324 75.7197C337.315 76.6809 332.206 76.3509 330.785 78.0439C329.35 79.9377 328.403 81.3437 326.379 82.0466L320.696 84.0409L307.191 88.2588L296.04 91.6877L282.564 96.0061L274.987 97.6991C273.193 98.1008 271.528 97.6991 270.007 96.537C265.888 97.8856 260.549 99.1911 256.56 101.157C248.824 106.852 243.887 115.145 241.046 124.169C236.74 137.913 228.933 149.118 218.112 158.386C212.831 162.92 207.693 165.89 200.747 167.324C178 171.987 159.53 189.002 153.359 211.34C148.049 230.58 155.727 250.507 143.27 268.054L129.263 287.809C121.442 298.842 119.432 313.72 125.905 326.517C129.177 314.021 134.186 303.289 141.304 292.974C147.159 284.495 153.058 276.561 160.865 269.847C171.069 258.484 185.908 260.794 189.438 255.328C192.093 251.21 190.586 244.539 187.128 242.789C178.617 238.485 167.179 262.487 157.894 253.664C154.292 250.235 157.148 242.588 160.549 239.245L175.833 224.224L192.438 207.711C205.124 195.085 216.118 181.671 227.125 167.138L227.154 167.152ZM379.049 121.443C378.877 120.64 377.858 119.348 377.398 119.607L375.289 120.855C373.509 121.917 371.514 126.249 373.968 127.555C376.609 128.947 379.752 124.657 379.034 121.429L379.049 121.443ZM285.09 249.733C284.875 250.565 285.42 252.803 286.052 253.362C286.583 253.836 288.061 254.553 288.85 254.539L301.795 254.281C308.325 254.151 312.918 255.844 318.084 259.029C325.69 263.721 335.248 261.727 342.539 257.336C349.356 253.233 353.661 246.906 353.446 238.643C353.144 226.821 355.053 215.53 359.56 204.181C356.216 197.553 353.532 190.911 353.13 183.508L352.039 163.235C351.666 161.6 350.791 159.591 349.743 158.888C348.696 158.185 345.596 158.028 344.605 158.845C333.167 168.372 328.489 179.935 332.134 194.741L338.793 221.771C339.869 226.118 340.415 230.709 338.607 234.64C337.143 237.825 334.244 239.776 331.115 239.848C319.72 240.135 321.586 220.408 316.936 207.983C315.257 203.478 310.449 201.613 306.33 203.923C300.862 207.008 296.126 211.054 292.783 216.534C291.347 218.887 291.721 222.746 292.467 225.243C295.796 236.347 287.76 239.13 285.062 249.747L285.09 249.733ZM231.33 309.659C231.115 320.104 230.268 330.448 227.211 340.233C224.743 348.109 220.107 354.895 215.759 361.753L206.961 375.612C203.431 381.178 203.689 387.52 205.182 393.789L208.483 407.591L216.821 400.073C228.244 389.758 242.912 386.688 257.693 390.117C278.546 394.966 298.667 382.441 303.187 361.681L305.268 349.357C308.641 329.444 316.161 306.876 332.722 294.897C335.09 293.189 336.985 291.539 338.937 289.186C339.209 285.169 339.224 281.626 338.678 277.68C331.187 279.015 325.088 278.455 317.898 277.207L301.164 303.892C295.926 312.242 292.223 321.094 288.075 330.018L274.944 358.252C273.997 360.289 271.93 362.413 270.323 363.919C267.582 366.487 263.047 367.061 260.506 363.977C255.713 358.123 259.071 350.806 250.618 342.227C246.227 337.765 243.285 332.528 242.553 326.13L239.238 297.178C238.864 293.964 239.281 289.717 240.888 287.192C243.285 283.419 248.724 284.151 251.149 287.364C256 293.806 258.21 301.267 258.885 309.286L260.205 315.613C260.535 317.22 263.032 319.057 264.525 319.186C266.017 319.315 268.73 318.153 269.921 316.704C276.235 308.999 290.041 288.943 286.281 282.673C284.746 280.105 281.258 279.933 278.603 279.947L268.285 280.019C265.013 280.048 262.716 277.336 262.171 274.194C260.334 263.534 264.582 256.935 257.765 251.21C246.356 241.641 255.354 230.637 252.082 215.601C250.92 210.264 250.905 204.899 251.565 199.619C252.312 193.636 248.724 189.978 243.285 189.246C237.286 188.443 231.445 188.888 226.709 193.249C220.724 198.758 210.98 211.914 214.74 215.53C215.371 216.147 217.682 216.462 218.514 216.061L225.145 212.775C226.651 212.029 229.751 212.488 230.584 213.794C231.244 214.841 231.904 217.438 231.258 218.743L224.671 232.301C221.628 238.556 219.504 244.654 219.82 251.813C220.366 263.764 222.159 291.898 213.42 292.63C212.099 292.745 209.602 291.683 208.798 290.636L201.852 281.511C200.604 279.861 196.973 278.512 195.093 278.814C193.442 279.072 190.558 280.794 189.481 282.501L182.349 293.821C181.861 294.595 179.722 295.614 179.177 295.011C176.752 292.371 179.966 284.911 176.967 279.56C173.968 274.208 159.257 285.686 158.396 304.136C158.325 305.642 159.645 307.909 160.721 308.626C164.381 311.037 168.213 308.196 171.542 304.523L177.211 298.268C178.259 298.828 179.091 300.937 178.761 301.998C174.054 316.876 165.931 329.989 153.89 339.802C149.412 343.461 144.519 345.77 138.448 346.861C141.921 356.688 141.318 366.817 136.295 375.928L129.134 386.616C125.56 391.939 124.8 397.591 127.426 403.517C132.578 415.08 141.577 424.09 152.426 430.718C160.578 435.697 168.959 439.283 178.689 439.8C181.301 439.943 186.324 439.369 187.156 436.514L188.85 413.459C189.668 402.412 186.539 376.917 178.072 370.734L170.451 365.182C165.156 361.322 169.777 355.354 174.743 350.361L182.98 342.055L201.924 316.962L209.76 308.282C213.204 304.466 217.711 302.113 222.934 301.568C227.326 301.109 231.474 304.48 231.359 309.645L231.33 309.659ZM213.233 327.407C207.22 325.097 195.236 346.617 201.407 350.318C208.813 354.766 218.902 329.587 213.233 327.407Z" fill="#fff"/><path d="M240.615 275.916C240.084 277.278 237.96 278.641 236.726 278.857C235.234 279.115 232.32 278.254 231.531 276.791C226.982 268.34 227.24 257.81 234.832 252.774C236.482 251.684 239.238 251.555 240.931 252.458C245.94 255.127 243.758 267.896 240.615 275.901V275.916Z" fill="#fff"/></g>`;
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

  // ------------------------------------------------------------------------------
  // Placement: an OVERLAY, never Instagram's own DOM. Proven the hard way 2026-08-17.
  //
  // The first shipped version did `container.appendChild(host)` plus
  // `container.style.position = "relative"` — writes INSIDE the React-owned tree.
  // Instagram server-renders and hydrates; a foreign child appearing mid-hydration is a
  // hydration mismatch (their console shows minified React error #418), and the
  // user-visible result was Instagram itself breaking: skeleton feeds that never
  // rendered, grids misrendering on fast scroll, a post modal that would not respond.
  // A/B-confirmed by the user: extension off → Instagram flawless; on → broken.
  //
  // So the page's DOM is now READ-ONLY to this script, structurally: every button lives
  // in one <carabiner-overlay> element appended to documentElement (NOT body — beside
  // Instagram's app root, outside anything React hydrates), position:fixed, and is
  // placed over its post by geometry from getBoundingClientRect, re-checked every
  // animation frame while any button exists. The frame loop doubles as the lifecycle:
  // a container React re-rendered away is disconnected, so its button is removed on the
  // next frame, and the next mutation-driven scan re-attaches to the replacement — the
  // same self-healing the old live-child check bought, without living in their tree.
  // ------------------------------------------------------------------------------
  const buttons = new Map(); // container element -> { host, url, place }
  let overlay = null;
  function overlayRoot() {
    if (overlay && overlay.isConnected) return overlay;
    overlay = document.createElement("carabiner-overlay");
    overlay.style.cssText = "position:fixed;top:0;left:0;width:0;height:0;z-index:2147483000;";
    document.documentElement.appendChild(overlay);
    return overlay;
  }

  // Shadow DOM so Instagram's CSS cannot reach our button and ours cannot leak into the
  // page. Without it, one Instagram style change silently reshapes the button.
  function makeButton(url, container) {
    const host = document.createElement("div");
    // left/top stay 0; place() moves the host with a transform, the cheapest style
    // write there is. pointer-events:auto because the overlay parent is 0×0.
    host.style.cssText = "position:fixed;left:0;top:0;z-index:2147483000;pointer-events:auto;display:none;";
    const root = host.attachShadow({ mode: "closed" });
    root.innerHTML = `
      <style>
        button { width:${SIZE}px; height:${SIZE}px; border:0; border-radius:50%;
                 background:rgba(0,0,0,.65); cursor:pointer; display:grid;
                 place-items:center; padding:0; backdrop-filter:blur(4px); }
        button:hover { background:rgba(45,91,255,.9); }
        svg { width:22px; height:22px; }
        .track { stroke:rgba(255,255,255,.25); }
        .fill  { stroke:#fff; stroke-linecap:round;
                 transform:rotate(-90deg); transform-origin:center;
                 transition:stroke-dasharray .2s linear; }
        .hidden { display:none; }
      </style>
      <button title="Save with Carabiner">
        <svg viewBox="0 0 24 24" fill="none" class="glyph">${MARK}</svg>
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
    const reset = () => paint(MARK, "");

    // Maps the tracker's semantic outcome to what the button actually shows. Fix round 2
    // minor: `cancelled` used to call the old settle("", ...) directly, which left a
    // glyph-less black circle — a deliberate act deserves the real rest state (the
    // Carabiner mark), not a blank one, so it now goes through reset().
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
      setRing(0.02);              // immediate acknowledgement, before anything downloads
      const id = nextId();
      tracker.start(id, { setRing, settle });
      try {
        // Resolved HERE, not in makeButton: `url` is closed over at attach time and the
        // buttons map rebinds only when it changes, so a slide index computed at attach
        // would be stale the moment the user swipes — and baking it into `url` would
        // destroy and recreate the button on every swipe. Reading the container is a
        // query, never a write (gotcha #36).
        // `location.search` is page-global, so it is passed WITH the post the page's own
        // path names (final review, Finding 1) — grabUrlFor trusts the query string only
        // when those agree. permalinkFromHref returns null for a feed ("/") or a profile
        // ("/handle/") path, which is simply "the address bar is not about a post".
        const grabUrl = grabUrlFor(url, {
          search: location.search,
          pagePermalink: permalinkFromHref(location.pathname),
          container,
        });
        // Breadcrumb for the one case that silently reverts to the old behaviour: a post
        // that HAS an active carousel dot we could not read, i.e. Instagram changed the
        // markup. Keyed on `aria-current` — language-neutral — and NOT on an English
        // label: the diagnostic built to announce a lost parse was blind to exactly the
        // localized case that loses it (final review, Finding 2). Deliberately not logged
        // for ordinary single posts, which have no dots and for which "no slide index" is
        // simply correct.
        if (grabUrl === url && container.querySelector("button[aria-current]")) {
          console.debug("[carabiner] carousel with no readable active slide — grabbing slide 1");
        }
        chrome.runtime.sendMessage({ type: "grab", id, url: grabUrl, browser: detectBrowser() }, (reply) => {
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

    // place() is the ONLY thing that positions the button: top-right of the container's
    // current viewport rect, hidden while the container is offscreen, degenerate
    // (React's zero-size skeletons), or too small to carry a button at all. Writes only
    // when the position actually changed, so a still page costs two rect reads and no
    // style work per frame per button.
    let lastX = null, lastY = null, lastShown = false;
    // The Save button this one sits beside, resolved lazily and cached. Re-resolved only
    // when it goes missing, because place() runs every animation frame for every button and
    // a querySelectorAll per frame per button is exactly the kind of cost that makes a page
    // feel heavy. `isConnected` is the re-resolve trigger: React swaps these nodes out on
    // re-render, and a detached element's rect is all zeros, which would park the button at
    // the top-left of the viewport instead of on the post.
    let saveEl = null;
    let lastMiss = 0;
    const MISS_RETRY_MS = 1000;
    const resolveSave = () => {
      if (saveEl && saveEl.isConnected) return saveEl;
      // Rate-limit the misses. A profile-grid thumbnail genuinely has no action bar, so
      // without this every grid button would re-scan its container 60 times a second
      // forever, searching for something that is never going to be there.
      const now = Date.now();
      if (!saveEl && now - lastMiss < MISS_RETRY_MS) return null;
      saveEl = findSaveButton(container);
      if (!saveEl) lastMiss = now;
      return saveEl;
    };

    const place = () => {
      const r = container.getBoundingClientRect();
      const shown = r.width >= SIZE + 16 && r.height >= SIZE + 16
        && r.bottom > 0 && r.top < window.innerHeight
        && r.right > 0 && r.left < window.innerWidth;
      if (shown !== lastShown) { host.style.display = shown ? "" : "none"; lastShown = shown; }
      if (!shown) return;

      // Beside Save when this post has an action bar; the post's top-right corner when it
      // does not. The fallback is deliberate and must stay: a profile grid has no bar at
      // all, and if Instagram reshapes its markup the button has to move back to the corner
      // rather than disappear (a missing button is indistinguishable from a broken
      // extension — the failure mode this project keeps paying for).
      let x, y;
      const save = resolveSave();
      const s = save && save.getBoundingClientRect();
      if (s && s.width > 0 && s.height > 0) {
        ({ x, y } = saveAnchorPosition(s, SIZE, ANCHOR_GAP));
      } else {
        x = Math.round(r.right - SIZE - 8);
        y = Math.round(r.top + 8);
      }
      if (x !== lastX || y !== lastY) {
        host.style.transform = `translate(${x}px,${y}px)`;
        lastX = x; lastY = y;
      }
    };

    return { host, place };
  }

  // Reposition every live button and reap the ones whose container React re-rendered
  // away (disconnected element → remove ours and the Map entry; the next mutation-driven
  // scan re-attaches to the replacement). Deliberately NOT a free-running rAF loop:
  // a standing loop burns battery on a still page and — measured — holds the test
  // process open forever. Instead this is coalesced one-shot work, driven by the three
  // things that can actually move a post: scrolling (capture:true, because Instagram
  // scrolls inner elements, not always the window), a resize, and DOM mutations (which
  // already drive scan()). A pure CSS animation with no DOM traffic could drift a
  // button between events; Instagram's layout moves are not that, and stillness costs
  // nothing this way.
  function reapAndPlace() {
    for (const [container, entry] of buttons) {
      if (!container.isConnected) {
        entry.host.remove();
        buttons.delete(container);
        continue;
      }
      entry.place();
    }
  }
  let placeScheduled = false;
  function schedulePlace() {
    if (placeScheduled) return;
    placeScheduled = true;
    requestAnimationFrame(() => {
      placeScheduled = false;
      reapAndPlace();
    });
  }
  window.addEventListener("scroll", schedulePlace, { capture: true, passive: true });
  window.addEventListener("resize", schedulePlace, { passive: true });

  // detectBrowser() lives in browser.js now, shared with worker.js (Finding 4, final
  // review) — manifest.json lists it immediately before this file in the same
  // content_scripts[].js array, so it's already a global by the time this IIFE runs. Not
  // imported here: it has no `export` (see browser.js's own header for why), so a
  // dynamic import() of it would resolve to an empty module namespace.

  // Every message from the worker carries the id of the grab it belongs to (fix round 1,
  // Finding 2) — routing and the watchdog itself both live in grabTracker.js now, so this
  // listener is just wiring.
  chrome.runtime.onMessage.addListener((msg) => {
    tracker.receive(msg);
  });

  function attach(container) {
    // NEVER writes to `container` — see the placement comment above makeButton. The
    // page's DOM is read-only to this script.
    const url = permalinkFor(container);
    const existing = buttons.get(container);
    if (existing) {
      if (!url || existing.url !== url) {
        // A virtualized list can RECYCLE a DOM node for a different post — same element,
        // new href. A stale mapping here would download the wrong post, which is the
        // worst bug this extension could have. Drop the button; re-attach below if the
        // element still resolves.
        existing.host.remove();
        buttons.delete(container);
      } else {
        return; // mapped, same post — nothing to do
      }
    }
    if (!url) return;                       // no shortcode, no button. Never throw.
    const { host, place } = makeButton(url, container);
    host.setAttribute(HOST_MARK, "1");
    overlayRoot().appendChild(host);
    buttons.set(container, { host, url, place });
    place();
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
  // querySelectorAll per batch — running it synchronously on every mutation batch was
  // wasteful. (Our own DOM writes all land inside the overlay now, and the observer
  // watches body, which does not contain the overlay — so a scan can no longer
  // schedule another scan, removing the old self-amplification risk entirely.)
  let scanScheduled = false;
  function scheduleScan() {
    if (scanScheduled) return;
    scanScheduled = true;
    requestAnimationFrame(() => {
      scanScheduled = false;
      scan();
      reapAndPlace();   // mutations move/replace posts — reap and reposition in the same frame
    });
  }

  new MutationObserver(scheduleScan).observe(document.body, { childList: true, subtree: true });
  scheduleScan();
})();
