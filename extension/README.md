# Carabiner browser extension (scaffolding)

Puts a download control on Instagram posts and hands the post URL to
`Carabiner.app`, which does the actual grab. This directory currently holds
only the scaffolding needed to load the extension and verify the local
channel between it and the app — see "What's here" below.

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

## Run the Safari converter

Safari doesn't load an unpacked extension directory directly — it needs an
Xcode-wrapped app extension, produced from this same source by Apple's
converter:

```bash
xcrun safari-web-extension-converter extension --macos-only --no-open \
  --project-location /tmp/carabiner-safari-spike
```

Open the generated Xcode project, run it once to register the extension,
then enable it in Safari → Settings → Extensions and allow it on
`instagram.com`. Use Safari's Web Inspector on the extension's background
page the same way you'd use Chrome's service worker console.

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

- `manifest.json` — MV3 manifest. The `icons` key from the design doc's
  manifest is deliberately omitted for now: `icons/icon128.png` belongs to a
  later task, and referencing a missing file would keep the extension from
  loading at all.
- `src/worker.js` — the background service worker skeleton described above.
- `src/content.js` — a stub (just a console.log) so the manifest is valid
  and the extension loads. The real content script (post detection, the
  download button, shortcode extraction) is a later task.
- `src/shortcode.js` — a finished, tested module the content script will use
  once it's real.
- `test/` — offline `node:test` coverage for `shortcode.js`.

## Not done here

Verifying the `Origin` header in a real Chrome and a real Safari session —
the whole reason this scaffolding exists — needs a human at a browser with
a logged-in Instagram session and, for Safari, Xcode. That verification has
not been performed as part of this scaffolding change. See the design doc's
Task 2 for the exact steps (`nc`-based header dump, the `sendMessage` calls
to run in each browser's console, and the escalation path if Safari doesn't
send an `Origin` header).
