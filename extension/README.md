# Carabiner browser extension

Puts a download control on Instagram posts and hands the post URL to
`Carabiner.app`, which does the actual grab. See "What's here" below for
what's implemented.

Zero runtime dependencies ship in the extension. `jsdom` in
`package.json` is a devDependency for the node:test suite only.

## Load unpacked in Chrome

1. `chrome://extensions`
2. Turn on **Developer mode** (top right).
3. **Load unpacked** → select this `extension/` directory.
4. Open an `instagram.com` tab so the content script and host permissions
   are live.
5. On the extensions page, click the extension's **service worker** link to
   open its dedicated console — that's where `worker.js` logs and where you
   can drive it manually (e.g. `chrome.runtime.sendMessage({type: "grab", ...})`).

## Safari: ships inside Carabiner.app

Safari doesn't load an unpacked extension directory directly — it needs an
Xcode-wrapped app extension. Rather than running Apple's
`safari-web-extension-converter` by hand (useful for a one-off spike, not for
something teammates should repeat), the extension ships as an app-extension
target — `CarabinerSafariExtension`, defined in `app/project.yml` — embedded
inside `Carabiner.app` itself. Safari users get it by installing the app; there
is no separate Safari install step.

`extension/build.sh` allowlist-copies `manifest.json`, `src/` and `icons/`
into `extension/dist/chrome/` (also used to zip the Chrome package — one
source tree, two delivery shapes), which `project.yml` then copies into the
appex's `Contents/Resources` at build time. It has to run at least once
before the *first* `xcodegen generate` on a fresh checkout — `dist/chrome`
is gitignored, and `xcodegen generate` fails outright if it's missing. After
that, the `CarabinerSafariExtension` target re-runs it automatically as a
pre-build script, so editing `extension/src/*.js` and rebuilding the app
picks up the change with no manual step. `scripts/release.sh` also runs it,
before `xcodegen generate`, for exactly the fresh-checkout case.

```bash
./extension/build.sh   # only required by hand once, before the first `xcodegen generate`
cd app && xcodegen generate && xcodebuild -scheme Carabiner build
```

Install the built app, then enable it in Safari → Settings → Extensions and
allow it on `instagram.com`. Use Safari's Web Inspector on the extension's
background page the same way you'd use Chrome's service worker console.

## The fixed port

The app listens on `127.0.0.1:51847` — fixed, not configurable — for
`POST /grab`. Both `manifest.json`'s `host_permissions` and `worker.js`'s
`ENDPOINT` hardcode it. If the app's listen port ever changes, both need to
change together.

## Only the service worker may call the app

`worker.js` is the *only* place in this extension that calls the app.
`chrome.runtime.onMessage` listens for `{type: "grab", url}` from the
content script and does the `fetch` itself, rather than having the content
script fetch the app directly.

This isn't a style preference — a fetch made from a content script runs in
the page's origin, so its `Origin` header would be `https://www.instagram.com`,
and the app is designed to reject that. A fetch made from the background
service worker carries the extension's own origin
(`chrome-extension://<id>` in Chrome, `safari-web-extension://<uuid>` in
Safari), which is what the app's access control is built to trust. Routing
every outbound call through the worker is what makes that trust boundary
hold — see the design doc for the full reasoning:
`docs/superpowers/specs/2026-08-12-browser-extension-design.md`.

## What's here

- `manifest.json` — MV3 manifest, including the `icons` key
  (`icons/icon128.png`, exported from the root `Carabiner_svg.svg`).
- `src/worker.js` — the background service worker. Talks to the app over
  the loopback socket (see "Only the service worker may call the app"
  above) and opens `carabiner://launch` to start the app if it isn't
  already listening.
- `src/content.js` — detects Instagram post containers, injects a download
  button per post, and drives it through its grab lifecycle (working ring,
  success/error state) via messages to/from the worker.
- `src/shortcode.js` — parses a post's shortcode/handle out of a permalink.
- `src/containers.js` — picks which elements on the page are eligible post
  containers for a button (deduplicating nested matches, e.g. an `<article>`
  and the permalink `<a>` inside it).
- `src/grabTracker.js` — routes worker progress/outcome messages to the
  button that owns each in-flight grab, and the watchdog that recovers a
  grab whose "done" message never arrives.
- `src/ring.js` — pure mapping from a progress/outcome event to how a
  button's progress ring should react.
- `src/ndjson.js` — line-buffers a decoded text stream into parsed JSON
  objects for the worker's NDJSON responses from the app; deliberately
  script-global (no `import`/`export`) since `worker.js` loads it via
  `importScripts`, not ES modules.
- `icons/icon128.png` — the OFF-PISTE mark, exported from the root
  `Carabiner_svg.svg`.
- `build.sh` — see "Safari: ships inside Carabiner.app" above.
- `test/` — offline `node:test` coverage for the pure modules above
  (`shortcode.js`, `containers.js`, `grabTracker.js`, `ring.js`,
  `ndjson.js`).

## Not done here

Verifying the `Origin` header in a real Chrome and a real Safari session, and
that Safari actually loads and enables the embedded extension, needs a human
at a browser with a logged-in Instagram session. Neither has been performed
by an agent working in this repo — no browser session is available in that
environment. See the design doc for the exact steps (`nc`-based header dump,
the `sendMessage` calls to run in each browser's console, and the escalation
path if Safari doesn't send an `Origin` header):
`docs/superpowers/specs/2026-08-12-browser-extension-design.md`.
