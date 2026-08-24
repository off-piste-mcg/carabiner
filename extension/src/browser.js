// Shared by worker.js and content.js — Finding 4, final review: `detectBrowser()` used to
// be copy-pasted once in each file, the same "one rule, two places to forget it" shape
// that produced this branch's origin-check and ring bugs. No export/import syntax, for
// the same reason ndjson.js has none: worker.js is a CLASSIC (non-module) service worker
// (see its own header comment — Safari's web-extension converter warns "type": "module"
// isn't supported there) and `importScripts` throws a SyntaxError on `export` at parse
// time. content.js is also a classic content script, so rather than round-trip this
// through a dynamic `import()` of a web-accessible resource (the mechanism content.js
// uses for its ESM-flavoured dependencies), manifest.json simply lists this file BEFORE
// content.js in the same `content_scripts[].js` array — both then execute as ordinary
// classic scripts in the same isolated-world global scope, so `detectBrowser` is already
// there as a plain global by the time content.js runs, exactly like `feedNDJSON` already
// is for worker.js via `importScripts("ndjson.js", "browser.js")`.
function detectBrowser() {
  const ua = navigator.userAgent;
  if (ua.includes("Safari") && !ua.includes("Chrome")) return "safari";
  // Edge deliberately advertises itself via an "Edg/" token specifically so sites CAN
  // tell it apart from Chrome — unlike Brave and Arc below, this one is worth actually
  // detecting rather than folding into the Chrome fallback. `Browser` (TabReader.swift)
  // already has a `.edge` case that reads Edge's own cookie jar via `--cookies-from-
  // browser edge`, so this is a real correctness win, not decoration.
  if (ua.includes("Edg/")) return "edge";
  // Brave and Arc deliberately present Chrome's own User-Agent string for site
  // compatibility — there is no UA signal left to catch them on, so they (and any other
  // unrecognised Chromium fork the Chrome Web Store installs into) fall back here. That
  // means carabiner reads THEIR Chrome-flavoured cookie jar rather than their own: not a
  // guess, but the one cookie jar every Chromium-based browser is guaranteed to have, and
  // the only honest default once there is nothing left to detect.
  return "chrome";
}
