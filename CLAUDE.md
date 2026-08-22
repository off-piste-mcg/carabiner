# CLAUDE.md — Carabiner

**Carabiner** — a small, trustworthy piece of kit that clips onto media and holds it.
A **local** macOS tool: paste/share a URL → clean, QuickTime-openable file in `~/Downloads`.

Read this first. It captures the built tool plus the non-obvious gotchas discovered the
hard way — treat "Known gotchas" as settled fact, not theory to re-test.

## What this project is

A local macOS tool that takes a pasted URL (Instagram first; YouTube / Pinterest
secondary), auto-detects image vs video, handles carousels (all slides OR one specific
slide via `img_index`), and saves clean files.

**Three front ends, one engine.** The bash `carabiner` script does all the grabbing; every
front end just calls it.

1. **`Carabiner.app`** (`app/`) — the native menu-bar app. **This is the primary UX going
   forward.** Open a post → ⌃⌥⌘V → file in `~/Downloads` + a branded notification.
   Currently dev-machine only: distribution needs Developer ID signing (spec phase 4).
2. **The macOS Shortcut** — the zero-install fallback for anyone who doesn't want the app,
   and how the tool shipped originally. Stays supported.
3. **The browser extension** (`extension/`) — an in-page download button on Instagram
   posts, for Chrome and Safari. It is a new way to **ask**, not a new way to download:
   it reads the post's shortcode out of the page and hands
   `https://www.instagram.com/p/<code>/` to `Carabiner.app` over a loopback HTTP channel,
   which runs the same script the hotkey does. No API scraping, no CDN URLs, no download
   code in the extension — so cookies, carousels, the QuickTime re-encode, filenames,
   `@user` attribution and the banners all keep working with no new code. It exists
   because the hotkey can only ever grab what the *tab URL* points at, which is useless
   on a feed (`instagram.com/`) or a profile grid (`instagram.com/<handle>/`). See
   `docs/superpowers/specs/2026-08-12-browser-extension-design.md`.

The app and the Shortcut **cannot share a hotkey** — a global chord has exactly one owner
(gotcha #14). If a teammate installs the app, they unbind the Shortcut's hotkey, or vice
versa. The extension is not in that fight: it has no chord, and it works alongside either.

## The single most important architectural fact

**Everything works because it runs locally as the logged-in user, using their own browser
cookies.** Do NOT turn this into a hosted website that accepts links from strangers.
Without a per-user browser session, Instagram refuses anonymous requests ("empty media
response"), and a public backend would need its own IG login → rate-limited/banned, and
against IG ToS. Keep it local. It's still shareable — each person runs it on their own Mac.

## Current state — BUILT

- **`carabiner`** — the unified tool. Parses the URL, detects platform, and routes:
  - **video → `yt-dlp`** then re-encode to 8-bit `yuv420p` H.264 (QuickTime-safe).
  - **image / full carousel → `gallery-dl`** (yt-dlp refuses carousel images).
  - Honours `?img_index=N`; flags: `-a` (all slides), `-s N` (one slide), `--silent`,
    `-o DIR`, `-b BROWSER`. Deterministic names from the shortcode
    (`_fixed`, `_sN`, `_silent`). Under `-a`, gallery-dl videos are re-encoded too.
  - **No-URL invocation** (for the hotkey): `resolve_url` reads the frontmost browser
    tab via AppleScript (Chrome/Safari/Brave/Edge/Arc), falling back to the clipboard —
    so you just open a post and fire the hotkey, no copying. See gotcha #8.
  - **Self-heals PATH**: exports `/opt/homebrew/bin:/usr/local/bin` so it finds its deps
    under the stripped-down environment Shortcuts/hotkeys provide (gotcha #8) — and, when
    the app supplies bundled binaries via `CARABINER_BIN`, prepends that ahead of
    Homebrew so the bundled copies win instead of being silently shadowed (gotcha #17).
  - **Notifications**: when headless (`[ -t 1 ]` is false, i.e. launched from the
    hotkey), fires a plain native macOS notification on success (filename summary) and on
    failure (the error) via `osascript display notification`. Silent in a terminal.
    Generic (Script Editor) icon — see gotcha #10 for why it isn't the logo.
    **Suppressed entirely when `CARABINER_NO_NOTIFY` is set**, which is how the app takes
    over notifications with its own branded banner. If you ever see *two* banners, or an
    unbranded one while using the app, the app is calling a copy of this script that
    predates that gate.
  - **Progress**: reports its stage on stderr as `::progress:` markers — always on, no
    flag to disable them. stdout is unchanged, so the Shortcut path (which only reads
    stdout) is unaffected; the app is the only consumer, via `GrabRunner`.
    One marker is metadata rather than a stage: `::progress:from:@user` names the
    Instagram account a grab came from (parsed from gallery-dl `--write-metadata` /
    yt-dlp `--write-info-json` sidecars — no extra network) and drives the app's
    "✓ Saved from @user" banner; a missing handle degrades to the plain "✓ Saved".
- **`setup.sh`** — installs the three deps via Homebrew, links `carabiner`/`clip`/`crab`.
- **`README.md`** — team setup + the macOS Shortcut wiring.
- **Shipped:** public repo at `github.com/off-piste-mcg/carabiner` (clone + `./setup.sh`).
  The macOS Shortcut is shared as an **iCloud link** in the README
  (`icloud.com/shortcuts/1633ebc20bf04369a20ccab25b38dc8b`) — one-click add, then each
  user sets their own hotkey (keyboard shortcuts aren't stored in a shared shortcut).
  The shortcut's Run Shell Script uses a portable one-liner so it finds `carabiner` on
  both Apple Silicon (`/opt/homebrew`) and Intel (`/usr/local`).
- **`app/`** — **`Carabiner.app`, the native Swift/AppKit menu-bar app (Phase 1 done).**
  A **regular Dock app since 2026-08-21** (no more `LSUIElement`): Dock tile with the
  running dot whenever it runs, pinnable via Options → Keep in Dock, and clicking the
  Dock icon opens Setup & Permissions (`applicationShouldHandleReopen` — which
  deliberately ignores `hasVisibleWindows`, because the status item is backed by a window
  and the flag reads true with nothing on screen; measured, gating on it left the Dock
  click doing nothing). A minimal main menu (app + Edit) fills the otherwise-empty menu
  bar when frontmost. The app icon is `app/Carabiner/AppIcon.icon`, a hand-authored
  Tahoe-native Icon Composer JSON (black fill, one flat white layer with the full
  mark-and-rope from `Carabiner_logo.jpg`): macOS 26 puts legacy pre-rounded icon PNGs on
  a gray backplate ring, which is why the old `AppIcon.appiconset` is gone — actool
  generates the macOS ≤ 15 `.icns` fallback from the same file, and
  `ASSETCATALOG_COMPILER_APPICON_NAME` is now explicit in `project.yml` (xcodegen only
  infers it while an `.appiconset` exists). Layer `scale` in that JSON is native image
  pixels per canvas point: the 2048px source on the 1024pt canvas needs 0.5 for
  full-bleed. See `docs/superpowers/specs/2026-08-21-dock-app-design.md`.
  The Dock click opens the **main window** (same day, second slice — and since
  2026-08-22 the OFF-PISTE **brand canvas**): `bg.jpg` full-bleed under a transparent
  titlebar (`fullSizeContentView`, aqua-pinned, 640×420 minimum, 720×460 default size),
  ABC Diatype Mono registered via `ATSApplicationFontsPath` (`BrandAssets`), and
  `BrandYellow` (#FAFA78) in the asset catalog — all read through `app/Carabiner/Brand.swift`,
  the single source (`Brand.yellow` / `Brand.mono` with a system-monospaced fallback /
  `Brand.backgroundImage` / `Brand.shortVersion` / `Brand.clockText`). **The licensed
  `.otf` is gitignored** — this is a public repo, so a checkout without it still builds
  and `Brand.mono` falls back to system monospaced; `bg.jpg` itself IS committed. Corner
  furniture on the canvas: a settings pill (top-right), a rotated version string (right
  edge), the hotkey hint (bottom-left), and the wordmark plus a live clock (bottom-right).
  Over that canvas sits a paste/drop grab box validated through `GrabGate.checkURL` (the
  URL half of the extension's gate, extracted so every surface shares one allowlist) plus
  the **recent-grabs history** — `GrabHistoryStore`, last 50 successful app-driven grabs
  as JSON in `~/Library/Application Support/Carabiner/`, recorded at the one funnel all
  grabs pass (`MenuBarController.grab(url:browser:)`'s completion), shown only when
  non-empty. Shortcut-path grabs bypass the app and can never appear there. **Settings is
  now an in-window slide-in panel**, not a separate window
  (`app/Carabiner/MainWindow/SettingsPanel.swift`): it reuses `OnboardingViewModel`
  untouched, and the panel's only own decision is the pure, tested
  `SettingsPanel.actionTitle`; Esc, the ✕, and the scrim all close it.
  **`OnboardingWindowController` and `OnboardingView` are deleted** — don't go looking for
  them — `MainWindowController` now owns the hotkey-test plumbing that used to live there.
  ⌘,, the status-menu item (retitled "Settings…") and first-launch auto-open all open the
  main window with the panel already open; the defaults key string is unchanged
  (`"onboardingShown"`). The Dock click itself is unchanged by this — it still opens the
  plain canvas, no panel. A URL dropped on the Dock tile grabs too:
  `CFBundleDocumentTypes` accepts `public.url` (document-type acceptance, not a scheme
  claim) and `dockOpenAction` routes carabiner:// vs allowlisted https vs junk. History
  rows for the YouTube/Pinterest paths render dimmed with no thumbnail — the script
  announces `saved to ~/Downloads` there, not a filename; making the engine announce real
  filenames on those paths is the natural follow-up. See
  `docs/superpowers/specs/2026-08-21-main-window-design.md` (grab box + history) and
  `docs/superpowers/specs/2026-08-22-brand-main-window-design.md` (brand canvas +
  in-window settings).
  **Found while verifying (2026-08-21), pre-existing and NOT caused by this work: the
  bundled yt-dlp cannot grab YouTube any more.** Same version as Homebrew's (2026.07.04),
  but YouTube now requires the `yt-dlp-ejs` JS-challenge component, which Homebrew's
  install ships and our PyInstaller `--onedir` tree (deps-2026.07.1) does not — bundled
  grabs see "Only images are available" and die with "Requested format is not available";
  Instagram is unaffected. Fix belongs in `build-deps.yml` (include yt-dlp-ejs, new deps
  release). Isolated with the CARABINER_BIN A/B: same URL, Homebrew PATH succeeds,
  bundled fails.
  OFF-PISTE logo status item, global ⌃⌥⌘V hotkey. The status
  item and the notification use *different* assets: the menu bar draws the `StatusIcon`
  vector asset (the SVG, template-rendered so macOS tints it to the bar), while the branded
  notification keeps the full-colour `AppIcon` — `UNUserNotificationCenter` always takes its
  icon from the bundle icon, so the two never need to match. Reads the
  front browser tab via AppleScript, shells out to this repo's `carabiner` script, and
  posts a **branded** notification with the filename (or "N files"). Swift owns the
  experience; bash still owns the grabbing — the app never re-implements the pipeline.
  While a grab is *actually downloading or converting*, the status item draws a progress
  ring around the mark (which shrinks to 10pt for the duration) — driven by `::progress:`
  markers the script writes to stderr, not by a guess. The ring deliberately does NOT
  appear at the hotkey: it reads as "downloading", so it waits for the first
  download/item/convert marker (`ProgressEvent.beginsActivity`) — during the carousel
  probe and the dialog there is no ring, and the working banner is the immediate
  feedback instead. See `docs/superpowers/specs/2026-07-31-menu-bar-progress-ring-design.md`.
  A **Launch at login** row (`SMAppService.mainApp`, added 2026-08-19) keeps Carabiner
  running so the extension's cold-launch prompt stays rare — Chrome's "Open Carabiner?"
  dialog has no "always allow" checkbox, so without it every cold launch asks. Off by
  default. Unlike every other row it can revoke itself (`unregister()` is real, where macOS
  offers no way to hand a TCC grant back), which is why `ToggleIntent` has a `.revoke` case.
  See gotcha #40 for the mapping that made it unreachable at first.
  First launch opens a branded **Setup & Permissions** window (reopenable via the
  status menu): per-permission Allow rows with live status — notifications, browser
  Automation (launches the browser first; the OS can neither prompt nor report for a
  closed target), System Events for the carousel dialog — plus a hotkey test that
  catches the silently-lost-chord case (gotcha #14). On fresh installs it is the only
  thing that triggers permission prompts. Verified 2026-08-02 on a `tccutil`-reset
  machine, including the spec's flagged assumption: the System Events grant made
  through the window does cover the script's osascript dialog (TCC attributes the
  child to the app). See `docs/superpowers/specs/2026-08-02-onboarding-design.md`.
  Built with XcodeGen (`xcodegen generate` from `app/`; the `.xcodeproj` and the generated
  `Info.plist` are gitignored — `project.yml` is the single source of truth). **Requires a
  development code signature to work at all — see gotcha #11.** Build with:
  ```bash
  export CARABINER_TEAM_ID=$(security find-certificate -a -c "Apple Development" -p \
    | openssl x509 -noout -subject | tr ',/' '\n\n' \
    | sed -nE 's/.*OU=([A-Z0-9]{10}).*/\1/p' | head -1)
  cd app && xcodegen generate && xcodebuild -scheme Carabiner -configuration Debug build
  ```
  The app and the Shortcut cannot share a hotkey (gotcha #14) — pick one.
- **`extension/`** — **the in-page Instagram button (MV3, one source tree, two builds).**
  A content script finds post containers, derives the permalink and injects a button in a
  **shadow root** — positioned since 2026-08-19 **beside Instagram's Save icon** in the
  action row (feed, post pages and the post modal alike), falling back to the post's
  top-right corner where there is no action bar, as on a profile grid. Save is found
  structurally by `src/actionBar.js` (first `<section>` with ≥3 outermost icon buttons; Save
  is the last), never by `aria-label`, which is localized. The button is 24px to match
  Instagram's own icons — exactly the size at which the mark stops being legible, so if it
  ever reads as a blob, simplify the mark rather than growing the button.
  Three placement facts, all earned from user reports on 2026-08-19/20 and all verified in
  a real browser (Wisse, Chrome) — see gotcha #41 for the reasoning behind each:
  buttons are anchored in **document** coordinates, not viewport ones, so the browser
  scrolls them with the page instead of this script chasing it; a button **hides while a
  `[role=dialog]` covers its post**, because geometry alone cannot see occlusion and the
  overlay outranks anything Instagram can draw; and the **post modal has its own button**
  again, reversing the 2026-08-17 exclusion now that placement can anchor to Save rather
  than the close X.
  The background service worker — and only it, see gotcha #30 — POSTs
  `{url, browser}` to the app at **`http://127.0.0.1:51847/grab`** and reads back an NDJSON
  stream of the same `::progress:` events that drive the menu-bar ring, which the button
  renders as its own ring. `GET /health` is how the app learns a browser's extension is
  really there, which is what turns the onboarding row green. The port is **fixed and
  hardcoded in two places** (`extension/manifest.json`'s `host_permissions` and
  `extension/src/worker.js`'s `ENDPOINT`); if it ever changes, both change together. A
  failed bind deliberately does **not** fall back to another port — the extension has no
  way to discover a moved one, so that would present as a button that does nothing.
  (Verified: `EADDRINUSE` → `GrabServer.state = .failed`, and `allowLocalEndpointReuse`
  does not permit co-binding. But nothing outside `GrabServer` reads that state yet — see
  "Known rough edges".) Access control is two gates, no pairing token: the `Origin` must
  be `chrome-extension://` or `safari-web-extension://` (a page cannot forge `Origin`, and
  Safari's is a per-install UUID so exact-ID allowlisting was never possible), and the URL
  must match the Instagram/YouTube/Pinterest allowlist, https only. Safari ships as an
  app-extension target (`app/CarabinerSafariExtension`) inside `Carabiner.app`, so Safari
  users install nothing extra; Chrome is an unlisted Web Store listing that **does not
  exist yet**. Scope is Instagram feed / profile grid / permalink pages — no Stories, no
  other sites (the hotkey stays the answer for YouTube and Pinterest).
  **The reels feed (`instagram.com/reels/`) gets no button either, and that is a scope
  boundary rather than a bug — measured live 2026-08-17, so don't re-diagnose it from
  scratch.** `selectContainers` accepts an `<article>` or a permalink-shaped `<a href>`;
  that page has **zero** articles, and its 35 post-shaped anchors are Instagram's own small
  affordances (`44x32`, `24x24`, `130x16` …), not posts. The reel itself is a `<div>`, so
  nothing sized ever becomes a container and `place()`'s `>= 48x48` + in-viewport test
  hides every button (measured: 14 hosts, 0 visible). Losing it costs little: on that page
  the tab URL names the reel, which is exactly what the hotkey handles. The cost that does
  exist is 14 shadow-root hosts created and repositioned every frame for anchors that can
  never show a button — bounded and invisible, but real, and the first thing to remove if
  reels support is ever added.
- **`files/`** — original seed: proven `igdl`/`igdls` functions + the `ig-grab.js`
  bookmarklet. Reference only.
- **`Carabiner_svg.svg`** (repo root) — the original brand-source SVG the status-bar icon
  was derived from. Not a stray duplicate of `app/Carabiner/Assets.xcassets/StatusIcon.imageset/carabiner-status.svg`:
  that asset-catalog copy is cropped to the mark's own bounds for the menu bar, while the
  root file is the uncropped source. Keep both.

**Decision that was made:** images fold into the paste-a-link flow via gallery-dl (the
click-to-pick bookmarklet is retired to `files/` as reference, not part of the tool).

**Decision that was made:** the app is the primary UX going forward; the Shortcut stays as
the zero-install fallback for anyone who doesn't want the app. Both drive the same script.

## Working on this project

**Where things are:** `carabiner` (the engine, bash, repo root) · `app/` (the Swift app;
`app/Carabiner/Server/` is the extension's loopback listener and its pure origin/URL gate,
`app/CarabinerSafariExtension/` is the thin appex wrapper that makes Safari load the
extension out of `Carabiner.app`) · `extension/` (the MV3 extension itself — `src/` is the
source of truth, `dist/` is a gitignored build product, `test/` is offline `node:test`
coverage of the pure modules run with `node --test` from `extension/`) · `test/` (offline
shell tests, no network — `test-path.sh` covers the `CARABINER_BIN`
resolution order, `test/test-progress.sh` covers the progress markers offline (stubbed
tools via `CARABINER_BIN`, no network), `test-release.sh` covers `release.sh`'s preflight
gate against a real local Debug build) · `scripts/` (`deps.lock` + `fetch-deps.sh`, the
pinned fetch for the bundled binaries; `release.sh`, the Developer ID build → notarize →
DMG → staple pipeline) · `.github/workflows/build-deps.yml`
(manual-dispatch CI that builds the bundled ffmpeg/gallery-dl — see "Where we are /
what's next") · `docs/superpowers/specs/` (design) · `docs/superpowers/plans/`
(implementation plans) · `files/` (historical reference only, not part of the tool).

**Building the app now has two prerequisites before `xcodegen`, both idempotent, so it
costs nothing to re-run them:**
```bash
./scripts/fetch-deps.sh   # ~42 MB on a cold run, then "✓ (cached)" forever
./extension/build.sh      # allowlist-copies manifest.json/src/icons into the gitignored
                          # extension/dist/chrome (+ the Chrome zip). REQUIRED before the
                          # FIRST `xcodegen generate` on a fresh checkout: xcodegen
                          # resolves the appex's sources at generate time and fails
                          # outright ("missing source directory") without it. After that,
                          # CarabinerSafariExtension's own preBuildScripts re-runs it on
                          # every xcodebuild, so editing extension/src/*.js and rebuilding
                          # picks the change up with no manual step. `scripts/release.sh`
                          # runs it too, before xcodegen, for the fresh-checkout case.
```
Skip `fetch-deps.sh` and you get a perfectly working app that quietly uses Homebrew
instead — which is the whole failure mode gotcha #17 exists to warn about, so check
`Resources/bin` is actually populated before concluding bundling works. Skipping
`extension/build.sh` fails loudly instead, at `xcodegen generate`.

**The `CARABINER_BIN` contract** is the interface between the two front ends and the
engine: the app sets it to its `Contents/Resources/bin` directory when a build has
bundled binaries, and the script prepends it ahead of Homebrew (gotcha #17). Unset
(the Shortcut, a terminal run, or an unbundled dev build of the app), the script's PATH
is unchanged from before Phase 2 existed. Never read `CARABINER_BIN` for anything other
than PATH order — it is not a feature flag, just where to look first.

**The script** needs no build. Test it directly — it is the fastest way to isolate whether
a bug is in the app or the engine:
```bash
CARABINER_NO_NOTIFY=1 ./carabiner -s 1 'https://www.instagram.com/p/SHORTCODE/'
bash -n carabiner   # syntax check
./test/test-path.sh # CARABINER_BIN / PATH resolution order, offline (no network, no grabs)
```

**The app** is generated by XcodeGen, so `Carabiner.xcodeproj` and `app/Carabiner/Info.plist`
are gitignored build products — edit `app/project.yml`, never them. Every build signs
(gotcha #11), so the team ID must be in the environment first:
```bash
export CARABINER_TEAM_ID=$(security find-certificate -a -c "Apple Development" -p \
  | openssl x509 -noout -subject | tr ',/' '\n\n' \
  | sed -nE 's/.*OU=([A-Z0-9]{10}).*/\1/p' | head -1)
cd app && xcodegen generate
xcodebuild -project Carabiner.xcodeproj -scheme Carabiner -destination 'platform=macOS' test
xcodebuild -project Carabiner.xcodeproj -scheme Carabiner -configuration Debug \
  -derivedDataPath build build
```
Install and run it — **always launch the bundle, never the inner binary**, or notifications
break (gotcha #11):
```bash
pkill -x Carabiner; rm -rf ~/Applications/Carabiner.app
cp -R build/Build/Products/Debug/Carabiner.app ~/Applications/ && open ~/Applications/Carabiner.app
```
Leave no unsigned copy of the same bundle id anywhere on disk — a stale `build/` or
DerivedData copy silently poisons notifications for the signed one.

**Debugging the app.** It logs every meaningful step (`grab hotkey registered as …`,
`grab hotkey fired`, `grabbing <url> (cookies: <browser>)`, `grab succeeded — <file>`, and
`extension server listening on 127.0.0.1:51847`). Those are `NSLog`, so
they go to the unified log — but `log show` is often unreadable from a sandboxed shell. The
reliable way to read them is to run the inner binary with output redirected, accepting that
notifications won't work in that mode:
```bash
~/Applications/Carabiner.app/Contents/MacOS/Carabiner > /tmp/carabiner.log 2>&1 &
```

**Foot-gun: the running app executes a bundled snapshot, not your working copy.**
`GrabRunner.swift` runs `Bundle.main`'s copy of the script at
`Contents/Resources/carabiner` (see `bundledExecutable()`) — a file XcodeGen copies in at
build time from `app/project.yml`'s `../carabiner` resource entry, not a symlink back into
the repo. Editing the repo's `carabiner` and re-running the *already-installed* app tests
nothing: you're still exercising whatever was in `Resources/` at the last build. This is
new since Phase 2 bundling started — before it, debugging via the app and debugging via
`./carabiner` directly were the same file. Rebuild and reinstall (`xcodegen generate` →
`xcodebuild` → the `cp -R`/`open` steps above) before trusting an app-driven test of a
script change; `CARABINER_NO_NOTIFY=1 ./carabiner …` directly is still the fast path for
iterating on the script itself.

The extension has the **same shape of trap and it is closed**: the Safari appex ships a
copy of `extension/dist/chrome`, not `extension/src`. `CarabinerSafariExtension`'s
`preBuildScripts` re-runs `extension/build.sh` on every `xcodebuild`, so a JS edit does
reach the built appex without running anything by hand (verified by a canary edit reaching
the built bundle). Chrome is a different story per install shape: "Load unpacked" against
`extension/` reads `src/` directly, so a reload in `chrome://extensions` is enough — but a
Chrome install made from `extension/dist/carabiner-chrome.zip` is a snapshot, so re-run
`./extension/build.sh` before rebuilding that zip.

**Verifying a grab worked — do NOT trust timestamps.** gallery-dl preserves Instagram's
original mtime *and* birth time, so a freshly downloaded image can be dated weeks ago and
`ls -lt` / `find -newermt` will not show it. Videos differ (ffmpeg re-encodes, so they get
a real time), which makes the trap worse. Snapshot filenames and diff:
```bash
ls -1 ~/Downloads > /tmp/before.txt   # …grab…   then:
ls -1 ~/Downloads | diff /tmp/before.txt - | grep '^>'
```

## Where we are / what's next

> ### ⚠️ READ THIS FIRST — there is unmerged work on a branch (updated 2026-08-16)
>
> **Branch `feat/browser-extension`, ~40 commits, NOT merged into `main`.** It adds the
> in-page Instagram download button for Chrome and Safari (a third front end — see "What
> this project is"). As of 2026-08-16 it is **working in both browsers, verified by a
> human**: buttons render on real Instagram pages, real grabs complete through the
> loopback channel, and the mixed video+image carousel behaves (This slide / All / Cancel
> downloads nothing). The button's rest glyph is the Carabiner mark since 22f30c7.
>
> Getting Safari there took one real fix: **pkd refuses an unsandboxed appex at
> discovery** ("plug-ins must be sandboxed"), so the extension silently never appeared in
> Safari's list. The sandbox requirement is on the **appex, not the app** — see gotcha
> #35 and commit 21493d0. The old fear that "Carabiner cannot be sandboxed" was aimed at
> the wrong bundle.
>
> **Still open before this ships**, from
> `docs/superpowers/plans/2026-08-14-browser-extension-manual-verification.md`
> (17 of 21 done, each tick dated):
> item 10 (dialog-left-open patience), 17 (the FDA-denied
> Safari→Chrome cookie fallback, which costs an FDA revoke plus the OS-forced relaunch),
> and 19 (the Chrome Web Store listing — `chrome://policy` is clean, so the $5 is
> unblocked; `OnboardingViewModel.chromeWebStoreURL` is still `PLACEHOLDER_ID`, which
> redirects to the Web Store home page rather than 404ing).
>
> **Item 11 (cold launch) is DONE as of 2026-08-18, Chrome only** (commit 0864b45). The
> cause was not the launch mechanism at all: `GET /health` is 403 to Chrome because a
> simple GET from an extension worker carries no `Origin` — gotcha #38, which also means
> the onboarding window's **Chrome row has never been able to turn green**. That half is
> fixed but unverified, and **Safari's cold-launch path is unverified too.**
>
> The **Setup & Permissions window is verified** as of 2026-08-17 (items 12-16), including
> the question that had been the sharpest unknown — a fresh Full Disk Access grant does not
> reach the running process, but macOS forces "Quit & Reopen" as part of granting, so no
> "quit and reopen" note is needed. That pass also caught a real silent failure in the
> Safari row's Allow. Both are gotcha #37.
>
> The design is `docs/superpowers/specs/2026-08-12-browser-extension-design.md`; the
> implementation plan is `docs/superpowers/plans/2026-08-12-browser-extension.md`. What
> that work earned the hard way is gotchas #28-#37 plus "Known rough edges" below.

Phase 1 of the app is **done and merged** (see the spec's phasing section, corrected after
the fact). Phase 2, bundling the binaries, is **partially done**:

- **Done (tasks 1-4):** the `CARABINER_BIN` PATH contract (gotcha #17) so bundled binaries
  win over Homebrew instead of being silently shadowed by it; the app-side wiring in
  `GrabRunner.swift` that points `CARABINER_BIN` at `Contents/Resources/bin` when a build
  has one; and `.github/workflows/build-deps.yml`, a manual-dispatch CI workflow that
  builds a static universal (arm64 + x86_64) ffmpeg and a universal2 gallery-dl from
  source. Building them ourselves is the only option: upstream ships no official macOS
  binary for gallery-dl at all, and no official static ffmpeg build — both projects
  expect you to compile or use a packager (Homebrew, in this repo's own case).
  **That workflow is green as of 2026-07-30** (run 30551341740): it produces a universal
  ffmpeg (`x86_64 arm64`, static, `minos 13.0`) and a universal2 gallery-dl carrying
  3780 extractors. Getting there took three runs and cost two real gotchas — see #18.
- **Done (tasks 5-6, 2026-07-30):** the artifacts are published as the **`deps-2026.07`**
  release, and `scripts/deps.lock` + `scripts/fetch-deps.sh` pull them into a gitignored
  `app/.deps/bin` with the sha256 verified *before* anything is unpacked. `app/project.yml`
  copies that directory into `Contents/Resources/bin` and signs each binary with the
  Hardened Runtime plus `app/BundledBinaries.entitlements` (gotchas #19 and #20 — both
  were earned the hard way here). A build with no `.deps/bin` still works: there is simply
  no `Resources/bin`, `GrabRunner.binDirectory()` returns nil, `CARABINER_BIN` stays unset
  and the script falls back to Homebrew exactly as before.
- **Done (task 7, 2026-07-30):** verified with `brew unlink yt-dlp ffmpeg gallery-dl` in
  force, so nothing could silently fall back. A real Instagram post was grabbed
  end-to-end through the app's own bundled binaries, re-encoded (well — remuxed), landed
  in `~/Downloads`, and was opened by QuickTime Player itself to confirm. `PATH`
  resolution pointed at `Contents/Resources/bin` for all three tools. Homebrew was
  relinked afterwards. Still open from the plan: README install instructions for app
  users (task 7 step 5), better written once the DMG exists.
- **Done (2026-07-30): the tools are `--onedir`.** `deps-2026.07.1` supersedes
  `deps-2026.07`. gallery-dl went 4.4s → **0.11s** per launch and yt-dlp 8.1s → **0.15s**,
  and `disable-library-validation` is gone from the project entirely (gotcha #20). One
  behaviour worth knowing: the **first** run of a freshly installed build costs ~5s while
  Gatekeeper validates the ~117 nested Mach-Os, then it settles. That is per install, not
  per launch — don't chase it as a regression.

**Phase 4 (distribution) is written but UNRUN as of 2026-08-10.** Organization enrolment
for OFF-PISTE B.V. came through, so it is no longer blocked. In place: a `Release` build
config in `app/project.yml` (Developer ID Application, Manual signing,
`CARABINER_RELEASE_TEAM_ID`, `--timestamp`), `scripts/release.sh` (preconditions →
build → preflight gate → notarize app → DMG → notarize DMG → staple → verify), and
`test/test-release.sh`. Design and plan:
`docs/superpowers/specs/2026-08-10-developer-id-distribution-design.md`.

Two manual steps gate the first run, both needing an interactive Apple login: create a
**Developer ID Application** certificate (Xcode → Settings → Accounts → Manage
Certificates; Account Holder role), and `xcrun notarytool store-credentials carabiner`
with an app-specific password. `release.sh` refuses to start without either and prints
the fix. **Nothing in phase 4 has ever produced a notarized artifact** — treat the first
run as the real test, and expect the gates to catch something.

Also closed here: README install instructions for app users (phase 2 task 7 step 5).
One trap left in the open: `releases/latest` resolves to the newest **non-prerelease**
release, which is currently `deps-2026.07.1`. The README's download link is correct only
while the app release is newest — publish future `deps-*` releases as **pre-releases** or
they will steal the link and send teammates to a release with no DMG in it.

**The browser extension: WORKING in both browsers, not yet shipped (verified 2026-08-16,
branch `feat/browser-extension`).** `extension/`'s offline suite is **118/118** (`node
--test` from `extension/`). Two notes on that number, because it has been wrong here
before: the figure recorded until 2026-08-17 was 64, and the real count at that moment was
67 — an implementer measured it, so trust `node --test` over this line. 89 was the
carousel slide-index work (below); the jump to 101 is the cold-launch fix (gotcha #38),
which added `src/launch.js` plus its tests; 112 adds `src/actionBar.js` and the first
tests placement has ever had; 118 is the overlay trio in gotcha #41 (occlusion, document
coordinates, the modal's button back).

**The button grabs the slide you are looking at, since 2026-08-17.** It did not before, and
the failure was the bad kind: swipe a feed carousel to slide 2, answer the dialog with
"This slide", and slide **1** landed in `~/Downloads` behind a green tick and a banner.
`shortcode.js` canonicalises to a bare `/p/CODE/`, and gotcha #15 says an absent
`img_index` means slide 1 — so "this slide" always meant the first one. `slideIndex.js`
now reads Instagram's own `aria-current="step"` carousel dot (language-neutral; the label
is parsed for its first integer, since `aria-label` is localized) and `content.js` resolves
it **at click time** — `url` is closed over at attach and the dedup map rebinds on `url`
change, so an index resolved at attach would be stale after a swipe and one baked into
`url` would recreate the button on every swipe. The page URL wins only when it names *that
same post*: `location.search` is page-global while a button belongs to one container, and
with a post modal open over the feed the two genuinely diverge. Design:
`docs/superpowers/specs/2026-08-17-carousel-slide-index-design.md`. **Confirmed in a real
browser 2026-08-17** (Wisse, Chrome: swiped a feed carousel to slide 3, answered "This
slide", slide 3 landed) — which also proves the `web_accessible_resources` entry, the one
part of this no test can see.

What a human has actually verified:

- **Verified 2026-08-14/16 (Wisse, real browsers, logged-in Instagram):** buttons render
  on the feed, profile grids and post pages in **both Chrome and Safari**; real grabs
  complete end to end through `POST /grab` (files in `~/Downloads`, branded banner); the
  **mixed video+image carousel** behaves — "This slide", "All", and Cancel downloads
  nothing with no banner (gotchas #15/#24's exact failure shapes, both clean). Safari
  needed the appex sandbox fix first (gotcha #35) plus Develop → Allow Unsigned
  Extensions. Earlier: both browsers send an extension `Origin`, Safari preflights where
  Chrome doesn't (gotcha #29), Safari cookies need Full Disk Access (gotcha #28), the
  parser is fixed against captured real markup (gotcha #31), and the hotkey path still
  works after the shared-grab-path refactor.
- **Verified 2026-08-17 (Wisse + measurement, items 12-16):** the whole Setup & Permissions
  window except the fallback — 5-row layout, the FDA row and its grant flow, the
  `Privacy_AllFiles` deep link, the Safari row's Allow (which failed silently first: gotcha
  #37), and `lastSeen` surviving an app restart. The FDA row's green was cross-checked with
  a real Safari-cookie grab, not trusted.
- **Verified 2026-08-18 (Wisse, Chrome, item 11):** cold launch. With Carabiner quit, a
  button click opens the "Open Carabiner?" prompt, launches the app, closes the launch tab,
  returns focus to the post and lands the file — re-checked on the cleaned build after all
  diagnostics were removed, not on the instrumented one. Gotcha #38 is what it cost.
  Cold launch works in **Safari** too (same day, and quicker than Chrome). Safari first
  reproduced the original failure, but that was **stale code, not a Safari difference**:
  the appex ships a build-time copy of the extension, so a JS fix reaches Chrome on a ⟳
  and reaches Safari only after `xcodebuild` + reinstall. Check that before diagnosing any
  Safari-only misbehaviour.
  The **Chrome onboarding row is verified green** as of 2026-08-18 — the first time it
  could be, since `ping()`'s bare GET had always been 403'd (gotcha #38).
- **Verified 2026-08-20 (Wisse, Chrome):** the three overlay fixes in gotcha #41, each
  reported by a user and confirmed fixed in a real browser — grid buttons no longer paint
  over the open post modal, the button no longer lags the page on scroll, and the modal has
  its own button beside Save again. The last of those also retired the risk flagged when it
  shipped: `findSaveButton` picks the modal's action bar, not a comment's like button,
  even though the comment list precedes the bar in DOM order. **Chrome only** — Safari has
  none of the three until `xcodebuild` + reinstall, since the appex ships a build-time copy
  (the 2026-08-18 entry above is the standing warning about exactly this).
- **NOT yet verified:** item 10 (dialog-left-open patience) and 17 (the Safari→Chrome
  cookie fallback end to end, which needs FDA revoked and therefore another OS-forced
  relaunch). Also unverified: gotcha #41's three fixes in **Safari**.

What is left before shipping, needing a human with a Google account:

1. **The Chrome Web Store listing does not exist.** `OnboardingViewModel.chromeWebStoreURL`
   is still `…/detail/PLACEHOLDER_ID`, so the Chrome row's Allow button opens the Web Store
   *home page* today (it redirects rather than 404ing, which is worse — it looks like
   nothing went wrong). `chrome://policy` is clean, so this is unblocked. Publishing is a $5
   one-off developer account, an **unlisted** listing, and a privacy justification that says
   plainly what the `127.0.0.1` host permission is for (handing the post URL to the
   companion app; the extension downloads nothing and collects nothing). Then the real ID
   replaces the placeholder and the app is rebuilt.
2. **The remaining checklist items (10-11, 17)** in the manual-verification doc.

### Known rough edges in the extension work (deferred, not forgotten)

None of these was a review finding left unfixed by accident — each was seen, judged
non-blocking, and consciously deferred. They are recorded here because the working ledger
that held them is scratch and is being deleted.

**RESOLVED in the final fix wave (2026-08-14) — kept because the reasoning is the useful part:**

- ~~`GrabRunner.run()` has no watchdog~~ **Fixed.** A hung `carabiner` child used to pin
  `busy = true` for the life of the app: every `/grab` returned 409 forever *and* the hotkey
  silently no-opped, with no user-visible cause and no recovery short of quitting. There is
  now an **inactivity** bound (any byte on stderr resets it; `.prompt` switches to the same
  3600s backstop `GrabServer` uses, because a human on a dialog is not a stall), and on
  expiry the child is terminated and an ordinary failure returned so `busy` clears through
  the existing completion path. The property the whole fix rests on was nearly wrong and was
  checked rather than assumed: `Process.terminate()` reaches the **process group**, so the
  yt-dlp/gallery-dl grandchild dies too and both pipes hit EOF in 0.07s. Had it only killed
  bash, `group.wait()` would still have blocked forever and the fix would have been inert.
- ~~A failed listener bind is invisible to the user~~ **Fixed**, and it was worse than
  cosmetic: a local process that binds 51847 *before* Carabiner starts wins, and the
  extension would then POST every permalink the user clicks to the squatter, which could
  fake progress and outcomes too. `browserButtonStatus` now consults `GrabServer.state`
  *before* `lastSeen` (so a stale-but-fresh check-in cannot paper over a lost port) and
  renders `.serverUnavailable`, which deliberately offers no Allow action — the previous
  `.notDetermined` path would have opened a Web Store page at a user whose real problem is a
  squatted port.
- ~~The 64 KB request cap has never been exercised over the wire~~ **Now covered** by a
  loopback smoke test that drives a real `GrabServer` over a real socket. The 5s connection
  deadline is still not exercised.

**Reachability of a real failure:**

- ~~A killed re-encode leaves a truncated file in `~/Downloads`~~ **Fixed 2026-08-14, and
  the note undersold it.** Measured before the fix: SIGTERM 4s into a 120s encode left a
  19 MB `_fixed.mp4` that QuickTime opens happily and that simply ends at 25s — not
  corrupt, just silently short, i.e. indistinguishable from a real grab until you watch it
  to the end. `reencode` now writes to a hidden sibling (`.<name>.part.mp4`, same
  directory) and renames on success, so the promotion is an atomic rename and a kill
  leaves nothing that looks like a grab. Two details are load-bearing and easy to undo by
  "tidying" the name: it must still end in `.mp4` (ffmpeg picks its muxer from the output
  extension and a bare `.part` fails outright), and it must sit in `$OUTDIR` (a rename
  across filesystems is a copy, which a watchdog can interrupt halfway). Verified both
  directions against the real bundled ffmpeg with a 10-bit source forcing a genuine
  libx264 pass: completing promotes the file and leaves no `.part`; killing the process
  group mid-encode leaves the hidden `.part.mp4` and **no** `ABC123_fixed.mp4`.
- ~~A killed grab leaks its 84 MB temp source into `~/Downloads`~~ **Fixed 2026-08-16**
  with a TERM/INT trap that sweeps all three temps (the `$$`-named source, the in-flight
  `.part`, gallery-dl's mktemp dir). Two properties worth keeping in mind before touching
  it: the trap only works *because* the watchdog signals the whole process group — bash
  runs a trap after the foreground child exits, and the child is dying of the same signal,
  so the trap fires in ~0.07s instead of waiting out the encode (a kill aimed at bash
  alone would stall it). And cleanup is by registration (`CLEANUP_PART`/`CLEANUP_GLTMP`),
  deliberately not a glob over the shared `$OUTDIR`, which could delete a concurrent
  grab's live encode. Verified with real group-kills mid-encode and mid-gallery: exit
  143, empty output dir, no mktemp dir left.
- **Nothing stops the listener.** There is still no `stop()`/`deinit`, so nothing cancels
  the listener or in-flight connections on teardown. The loopback tests work around it with
  one port per test method rather than tearing down, which leaves a handful of listeners
  alive for the test process's lifetime.
- **`watchdog.fired` is read unsynchronized** from the calling thread while the timer queue
  writes it under a lock (`cancel()` does not wait for an in-flight handler). Benign today,
  but strict concurrency checking or TSan will flag it.
- ~~The 5s connection deadline has never been exercised over the wire~~ **Exercised
  2026-08-14, and it works.** A socket opened to `127.0.0.1:51847` that then sends nothing
  is closed by the app after **5.25s** with zero bytes written. Same session: `curl
  /health` returns **403**, which is gate 1 (no extension `Origin`) doing its job.

**Bounded leaks and inefficiencies, all judged acceptable:**

- On normal completion nothing cancels the pending deadline work item, so a stale timer
  holds a strong reference to an already-cancelled `NWConnection` for up to 600s (3600s if
  the last event was a prompt). Not a file-descriptor leak.
- A grab whose watchdog fired and which never sends another message stays in the
  extension's tracking map for the tab's lifetime. This is the deliberate price of "amber
  must not delete" (gotcha #33) — bounded by clicks per tab, two small closures each.
- The container scan (`containers.js`, driven at most once per animation frame from
  `content.js`) sweeps every anchor in the document and regexes each, which is strictly
  more work than the CSS prefilter it replaced. Cheap and bounded, but it is the first
  place to look if the page ever feels heavy. (Since the overlay refactor — gotcha #36 —
  our own DOM writes land outside `body`, so a scan can no longer schedule another scan;
  the old self-amplification risk is structurally gone.)
- Invalid UTF-8 or LF-only request framing never returns 400 — the parser cannot tell
  incomplete from malformed there, so such a request waits out the deadline instead.

**Latent, currently unreachable, worth knowing before touching that code:**

- Absolute hrefs (`https://www.instagram.com/p/CODE/`) are not matched by the permalink
  parser. Pre-existing; both real fixtures contain zero of them and Instagram does not
  appear to emit them. Worth remembering if the button ever "just stops".
- `GrabGate` returns `URL.absoluteString`, which neutralises CR/LF/space but **not** shell
  metacharacters. Inert today because `GrabRunner` passes `[url]` as an argument array with
  no shell involved, and inert in an HTTP header. It only matters if some future path
  interpolates an accepted URL into a shell string.
- Prose-only defect: the fixtures' comment counts are misstated in a test comment and in
  commit messages (`permalink.html` actually has 13 comment permalinks / 14 post-shaped
  anchors; `feed-post.html` has 2, not "one"). The *behaviour* and the counts in gotcha #31
  are correct; only that prose is wrong.

**Test-coverage limits, disclosed rather than papered over:**

- `test/test-release.sh` checks the positive Developer-ID/timestamp direction against a
  generic signed binary, not against a real Developer-ID-signed appex — no Developer ID
  certificate exists on this machine. Structural, not a regression.
- The pinning tests around the connection deadline have teeth at the pure-decision layer
  only; see gotcha #34's last bullet.

## Working logic (proven — reuse, don't reinvent)

**Video (with sound):**
```bash
yt-dlp --cookies-from-browser chrome -o "src.%(ext)s" "URL"
ffmpeg -y -i "src.mp4" -c:v libx264 -c:a aac -pix_fmt yuv420p "OUT.mp4"
```
**Video (silent):** add `-f "bv"` to yt-dlp and `-an` to ffmpeg (drop `-c:a aac`).

**Shortcode parse** (`/p/`, `/reel/`, `/reels/`, `/tv/`):
```bash
sed -nE 's#.*/(p|reel|reels|tv)/([^/?]+).*#\2#p'
```

**Carousel:** yt-dlp `--playlist-items N`; gallery-dl `--range N`. Parse `img_index=N`
from the URL for "just this slide".

## Known gotchas (settled — do not re-litigate by trial and error)

1. **Cookies are mandatory.** Anonymous IG returns "empty media response".
   `--cookies-from-browser chrome` (or safari/firefox/brave/edge) is required. Both
   yt-dlp and gallery-dl read them.
2. **IG videos are streaming blobs.** A browser/bookmarklet cannot save them (`<video>`
   src is a `blob:` MediaSource, assembled from separate audio+video streams). yt-dlp is
   required — this is why the tool can't be pure-browser.
3. **QuickTime rejects IG's pixel formats.** Files download but won't open (esp.
   AI-generated 10-bit / yuv444p). Fix = re-encode to 8-bit `-pix_fmt yuv420p`. The full
   libx264 re-encode is the guaranteed fix and the safe default.
4. **yt-dlp will NOT serve carousel images** ("No video formats found!"). Use
   **gallery-dl** for images and full-carousel grabs (reads the same browser cookies).
   The tool detects this: it tries yt-dlp, and on "no video" falls back to gallery-dl.
5. **Cross-origin `download` attribute fails** (image on cdninstagram.com, page on
   instagram.com) — historical note explaining the old bookmarklet's open-a-tab fallback.
   Not relevant to the shell tool.
6. **Home-vs-Downloads confusion.** The tool writes to `~/Downloads` (or `-o DIR`), never
   the invocation directory.
7. **Filename guessing bites.** yt-dlp's `%(uploader_id)s` is a numeric ID, not the
   handle. Names come deterministically from the shortcode.
8. **macOS Shortcuts hand you a minimal environment.** A Shortcut/Quick-Action/hotkey
   runs the script with a bare `PATH` (`/usr/bin:/bin:/usr/sbin:/sbin`) that excludes
   `/opt/homebrew/bin` — so bare `yt-dlp`/`gallery-dl`/`ffmpeg` calls fail even though a
   terminal run works. Carabiner fixes its own `PATH` at the top. Also: a global hotkey
   has no notion of "the post you're looking at", so Carabiner reads the front browser
   tab via `osascript` (both `osascript` and `pbpaste` live in `/usr/bin`, so they
   survive the minimal PATH). Firefox exposes no active-tab AppleScript → clipboard.
9. **The carousel prompt is intentionally a plain native dialog — don't re-brand it.**
   We explored swiftDialog (branded, needs a password'd cask install) and a custom
   Swift + WKWebView dialog (pixel-perfect, but needs Xcode to build per-machine and a
   downloaded binary trips Gatekeeper). Both were rejected: Carabiner is shared as a
   repo each teammate runs on their own Mac, and a branded dialog would look different
   (or break) depending on what they have installed. The native `osascript` dialog is
   the only option that's zero-dependency and identical on every Mac. Consistency won
   over polish — a deliberate decision, not a missing feature.

   **Partly superseded (2026-07-30).** The objection was to branded dialog *engines*, not
   to branding as such. `display dialog … with icon` takes a plain `.icns`, so the prompt
   now carries the OFF-PISTE logo from `assets/Carabiner.icns` — no cask, no per-machine
   Xcode build, identical on every Mac, and it brands the Shortcut's prompt too. The
   dialog itself is still the stock native one and should stay that way. Because the icon
   is a repo file, `carabiner` resolves its own real directory (following the symlinks
   `setup.sh` drops in Homebrew's bin) rather than trusting `$PWD`; if the file is
   missing the prompt falls back to `with icon note` instead of failing.
10. **Notifications are a plain native banner — a custom logo icon isn't worth it.**
    `osascript display notification` reliably banners but is attributed to Script Editor
    (generic icon), and that icon can't be changed. We built the obvious fix — a
    `Carabiner.app` AppleScript applet with the logo baked into an Apple rounded-rect
    `.icns` — and it only half-worked: the name showed but the icon stayed generic (the
    notification-icon cache is keyed by bundle id), and the moment we gave it a real
    bundle id macOS treated it as a new, UN-authorised app and dropped its notifications
    entirely. Custom-icon notifications require per-app notification authorisation granted
    **per machine** (and unsigned applets are flaky about even appearing in System
    Settings to grant) — the same portability problem as the branded dialog (gotcha #9).
    So notifications stay plain. Don't re-attempt the applet route for this shared tool.
    (`LOGO.jpg` is kept in the repo as the brand asset, but nothing consumes it.)

    **Superseded for `Carabiner.app` (2026-07-29).** The applet route was the wrong
    vehicle, not the wrong goal. A *signed* app bundle posting via
    `UNUserNotificationCenter` gets the logo, the app name, and a real authorisation
    prompt — verified working. The shell tool keeps its plain banner; the app is branded.
    See gotcha #11 for the condition that makes it work.

11. **The app's branded notification REQUIRES a real code signature — this is not
    deferrable to a distribution phase.** macOS refuses to register an ad-hoc /
    linker-signed bundle for user notifications: `requestAuthorization` fails instantly
    with `UNErrorDomain error 1` (`notificationsNotAllowed`), **no prompt is ever shown**,
    and every `add(request)` fails. Worse, an unsigned copy of the same bundle id anywhere
    on disk registers a team-less `NOTIFICATION#:com.offpiste.carabiner` record with
    LaunchServices that poisons the signed one — so a stray `xcodebuild` output in
    DerivedData silently breaks notifications for the properly signed app. Two consequences:
    every build signs (`CODE_SIGN_STYLE: Automatic` in `app/project.yml`), and unsigned
    build products must not be left lying around. Launch matters too: launch the bundle
    (`open`), never the inner binary — direct exec skips LaunchServices, so the bundle
    identity `UNUserNotificationCenter` needs is missing and authorisation fails.

12. **The Team ID is in the certificate's OU field, NOT the parenthetical in the identity
    name.** `security find-identity` prints `Apple Development: you@example.com (3KQ6AH5M2C)`
    — that parenthetical is the *agent* ID, and signing with it fails with "No signing
    certificate ... matching team ID". The real Team ID:
    ```bash
    security find-certificate -a -c "Apple Development" -p \
      | openssl x509 -noout -subject | tr ',/' '\n\n' \
      | sed -nE 's/.*OU=([A-Z0-9]{10}).*/\1/p' | head -1
    ```

13. **iCloud-synced folders break `codesign`.** This repo lives under `~/Documents`, which
    is iCloud-synced, and the file provider stamps `com.apple.FinderInfo` (plus
    `com.apple.fileprovider.fpfs#P`) onto the built `.app`. `codesign` rejects those:
    *"resource fork, Finder information, or similar detritus not allowed"*. `app/project.yml`
    carries a `postBuildScripts` phase that runs `xattr -cr` on the bundle — post-build
    scripts run *before* Xcode's CodeSign step, which is why that is the right hook.

    **The strip is a race, not a fix — build outside iCloud instead (2026-08-11).** The
    xattr strip only wins if the file provider does not re-stamp the bundle between it and
    CodeSign, and under sync pressure it loses. It lost repeatedly on 2026-08-11 while
    iCloud was uploading two 72 MB DMGs sitting in `dist/`: the *first* `xcodebuild` after
    a test run failed with the detritus error every time, and a retry usually passed —
    which is exactly the shape that gets misread as a flake and worked around.

    The real fix is to keep the build products out of iCloud entirely, by pointing
    `-derivedDataPath` somewhere unsynced:
    ```bash
    xcodebuild -project Carabiner.xcodeproj -scheme Carabiner \
      -configuration Debug -derivedDataPath /tmp/carabiner-dd build
    ```
    Measured: **3/3 consecutive clean builds** to `/tmp` versus repeated failures to
    `app/build`, and the iCloud-built bundle carried 3 xattrs against 1. This is also why
    `scripts/release.sh` has never once hit it — it stages into `mktemp -d`. Keep the
    strip anyway: it is what protects the release path's final bundle root.

14. **A global hotkey is exclusive, and losing it is silent.** `RegisterEventHotKey` fails
    outright if another app already owns the chord — and neither it nor the
    `KeyboardShortcuts` package reports that. While the macOS Shortcut was still bound to
    ⌃⌥⌘V, every press went to the Shortcut and the app never heard about it, which looked
    exactly like a broken app. The app now logs the chord it registered and every fire.
    Only one thing can own a chord: if the app has the hotkey, unbind the Shortcut's.

15. **`img_index` is absent on slide 1 — never use it to detect a carousel.** Instagram
    adds `?img_index=N` to the URL only once you navigate *off* the first slide, so a
    carousel you have just opened is indistinguishable from a single post by URL alone.
    The carousel prompt used to be gated on `img_index` being present, which meant
    opening a carousel and firing the hotkey straight away skipped the question entirely
    and silently grabbed all twelve slides — and it looked like the prompt was broken,
    because on any post you *had* scrolled it worked fine. Detection is now
    `ig_item_count` (a `gallery-dl -g` probe) on `/p/` URLs, with no `img_index` simply
    meaning slide 1. The probe is skipped for `/reel/`, `/reels/` and `/tv/`, which are
    always a single video, so reels don't pay for a network round-trip they can't use.

    **The same symptom came back by a second route (fixed 2026-07-30).** `gallery-dl -g`
    does not print one uniform line per slide: an image slide is a plain URL, but a
    **video** slide is prefixed `ytdl:` and is followed by an indented `| ` continuation
    line. `ig_item_count` matched only `^https?://`, so it counted zero video slides — a
    two-slide video+image carousel counted as **1**, the prompt never fired, and the tool
    silently grabbed the whole set, which is exactly the failure above. It is invisible on
    all-image carousels because those count correctly, so it survives any test that
    doesn't use a mixed post. The pattern is now `^(ytdl:)?https?://`, still anchored so
    the `| ` continuation line isn't double-counted. Lesson worth keeping: test carousel
    changes against a post that actually mixes video and images — both posts on the
    OFF-PISTE account do, which is how this surfaced.

16. **Hardened Runtime silently kills the app's Apple Events — turn it on early, not at
    release time.** Notarization requires the Hardened Runtime, and under it an app may
    not *send* Apple Events without `com.apple.security.automation.apple-events`. That is
    Carabiner's entire input path (reading the front browser tab, and the System Events
    carousel dialog), so enabling it for the first time in a release build would mean the
    first notarized DMG is the first run of the real thing. It is on in every build now,
    with the entitlement declared in `app/project.yml`. `NSAppleEventsUsageDescription` is
    only the *text* of the permission prompt — the entitlement is permission to ask.
    Verify a build with:
    ```bash
    codesign -dv Carabiner.app 2>&1 | grep flags          # want flags=0x10000(runtime)
    codesign -d --entitlements - --xml Carabiner.app | plutil -p -
    ```
    Note `com.apple.security.get-task-allow` in that output: Xcode adds it to **Debug**
    builds only, and notarization **rejects** any binary carrying it. Notarize Release
    builds, never a Debug one.

17. **`carabiner`'s PATH order is the entire point of bundling — get it backwards and
    bundling silently does nothing.** Gotcha #8 explains why the script prepends
    `/opt/homebrew/bin:/usr/local/bin` at all: a global hotkey hands it a stripped-down
    PATH that can't find Homebrew's yt-dlp/ffmpeg/gallery-dl. That prepend used to run
    *unconditionally* — so once the app started bundling its own copies of those three
    tools, Homebrew still won the PATH race on any machine that also had them installed
    via `brew`. That's every dev machine this gets tested on, so bundling would have
    *looked* like it worked (the app runs fine) while silently grabbing the Homebrew
    binaries instead of the bundled ones — a regression nobody would see until a machine
    without Homebrew tried it and failed differently, or a Homebrew upgrade changed
    behaviour the bundled binaries were pinned against. The fix: `CARABINER_BIN`, set by
    the app (`GrabRunner.swift`) to its `Contents/Resources/bin` directory, is now
    prepended *ahead of* Homebrew — `$CARABINER_BIN:/opt/homebrew/bin:/usr/local/bin:$PATH`
    — so app-supplied binaries win, Homebrew is still the fallback for the Shortcut and
    terminal, and an unset `CARABINER_BIN` (an unbundled dev build) leaves the old
    behaviour byte-for-byte unchanged. The only honest way to test this is to move
    Homebrew's copies aside (`brew unlink yt-dlp ffmpeg gallery-dl` or rename them) and
    grab something for real — a PATH bug that Homebrew can silently absorb will pass
    every test run on a machine that has Homebrew installed. `test/test-path.sh` covers
    the resolution order offline (no network, stubbed binaries) so this doesn't require a
    real grab every time, but it does not substitute for the no-Homebrew check before
    trusting a bundled build.

18. **The build runner's Homebrew leaks into the ffmpeg you ship — pass
    `--disable-autodetect`.** ffmpeg's `configure` scans the host and links whatever it
    finds. GitHub's macOS runners carry a Homebrew X11 stack, so a plain
    `--enable-static` build happily linked `libxcb`, `libX11`, `libXau` and `libXdmcp`
    for screen-grab devices this tool never uses — producing an "ffmpeg" that runs
    perfectly on the runner and dies on any Mac without those dylibs, which is the exact
    failure bundling exists to prevent. `--disable-autodetect` fixes the class rather
    than the four libraries: only what is explicitly requested gets linked, on any
    runner, whatever Homebrew happens to have installed. `zlib` is re-enabled explicitly
    (it lives in `/usr/lib`, so it is a system library, and some demuxers need it).
    This was caught by the workflow's own `otool -L` gate, which is why that gate must
    fail the step when `otool` itself fails — see the comment on it. Related: x264's
    `configure` **aborts** without an assembler rather than falling back to
    `--disable-asm`, and the runners don't ship `nasm`, so the workflow installs it.

19. **Nothing in `Contents/Resources` gets signed for you.** Xcode auto-signs nested code
    only in `Frameworks`, `PlugIns` and `XPCServices`; a Mach-O in `Resources` is sealed
    as *data* and left unsigned, and notarization rejects the whole app for it. The
    bundled binaries are signed by a `postBuildScripts` phase with `--options runtime`,
    which works because post-build scripts run *before* Xcode's CodeSign step — the same
    window the iCloud xattr strip uses (gotcha #13). Verify with
    `codesign -dv <binary> | grep flags` — every one must show `0x10000(runtime)`.

    **Their order matters, and it isn't the obvious one.** The xattr strip must be the
    **last** post-build script. It was fine as the first while it was the only one, but
    signing ~90 MB of bundled binaries takes long enough that iCloud's file provider
    re-stamps the bundle root in that window, and the build dies on detritus that had
    already been stripped once. Add new post-build scripts *above* the strip, never below.

20. **RESOLVED 2026-07-30 — kept because the reasoning is what stops it coming back.**
    Both Python tools are PyInstaller **`--onedir`** builds now, so every library they load
    is an ordinary file we sign with our own team ID, library validation is satisfied, and
    **no `disable-library-validation` entitlement exists anywhere in the project.** Do not
    re-add it. If a bundled tool ever dies at startup with *"mapping process and mapped
    file (non-platform) have different Team IDs"*, the cause is a Mach-O inside its tree
    that the signing loop missed — find it (`codesign -dv` each file) rather than granting
    the entitlement, which would paper over an unsigned library.

    The original entry, which explains why the trap is subtle:

    > **PyInstaller binaries need `disable-library-validation` — on the binaries, not on the
    app.** `yt-dlp_macos` and our `gallery-dl` are one-file PyInstaller builds: they unpack
    their own Python framework and `.so` files to a temp directory and `dlopen` them. Those
    libraries aren't signed by us, so once the launcher is re-signed with the Hardened
    Runtime (gotcha #19) library validation refuses to map them and both tools die
    instantly with *"mapping process and mapped file (non-platform) have different Team
    IDs"*. The trap is where the entitlement goes: putting
    `com.apple.security.cs.disable-library-validation` on `Carabiner.app` — the obvious
    reading, and what the plan originally said — **does nothing**, because yt-dlp and
    gallery-dl run as *child processes*, and a process is governed by its own signature.
    Nothing is inherited from the parent. It lives in `app/BundledBinaries.entitlements`
    and is passed via `--entitlements` when each binary is signed; the app itself does not
    carry it and shouldn't, since it never loads a foreign library.

    Two smaller teeth came off that work. One is now moot — there is no entitlements plist
    any more — but worth knowing if you ever write one: a **double hyphen is illegal inside
    an XML comment**, and documenting `--options runtime` in such a file makes `codesign`
    fail with `AMFIUnserializeXML: syntax error near line N`, with no hint that it means
    XML. The other is still live: the build's post-signing smoke test checks **exit codes,
    not output**, because `ffmpeg` wants `-version`, exits 8 on `--version`, and prints its
    version banner *before* failing — so an output-only check reads as a pass on a tool
    that just broke.

21. **Speed comes from not launching things, not from faster code — and the bundled
    binaries are the slow part.** Measured on this machine, worst case first:
    - **PyInstaller one-file startup dominated everything — fixed 2026-07-30 by `--onedir`.**
      The one-file builds took **7.9s** (`yt-dlp`) and **4.3s** (`gallery-dl`) just to reach
      `--version`, because each unpacks its whole embedded Python framework to a fresh temp
      dir on *every* launch. Our code signature was not the cause — the ad-hoc CI binaries
      were identically slow (7.89s vs 7.97s), so this was never a signing problem to chase.
      `--onedir` starts in **0.09s**, i.e. level with a plain Homebrew Python install
      (0.07s), because there is nothing to unpack. `build-deps.yml` builds both tools that
      way now, including yt-dlp, which we build ourselves since upstream ships only a
      one-file asset. Keep it that way: reverting to `--onefile` would silently cost ~50×
      startup *and* drag back the entitlement in gotcha #20.
    - **Re-encoding was unconditional.** A 45s reel that was *already* 8-bit yuv420p H.264
      cost 12.3s of libx264 to produce a slightly worse copy of itself. `plan_reencode`
      now probes with one `ffmpeg -i` (~0.05s) and stream-copies when the video is already
      safe: **12.3s → 0.2s**. Only genuinely odd files (gotcha #3's 10-bit / yuv444p) pay
      for the encode. The pixel-format test matches `yuv420p` followed by a non-alphanumeric
      **on purpose** — `yuv420p10le` contains `yuv420p` as a prefix and is exactly the file
      that must never be copied.
    - **The carousel probe is a whole extra tool launch.** It is skipped entirely when
      `img_index` is ≥ 2, which proves a carousel from the URL alone. This does not
      invert: a *missing* `img_index` still proves nothing (gotcha #15), so that path
      still probes. When the probe is skipped the slide count is unknown, and the prompt
      is written to read correctly without it.

    There is no `ffprobe` in the bundle — only `ffmpeg`, `yt-dlp` and `gallery-dl` — which
    is why the probe parses `ffmpeg -i` stderr rather than using the obvious tool.

22. **The outcome banner must NEVER reuse the working banner's identifier — same-id
    "replace in place" only re-presents while the old banner is still on screen.**
    Corrected 2026-08-02; this entry previously prescribed the same-id scheme, and that
    is exactly the bug it caused. Posting a `UNNotificationRequest` whose identifier is
    already *delivered* replaces the entry in Notification Centre **without showing a new
    banner** (documented UNUserNotificationCenter behaviour). While the old banner is
    still on screen the replacement is visible, which is why the same-id scheme looked
    verified: fast single grabs finished inside the banner's ~5s lifetime. Every carousel
    finished after it, so "✓ Saved N files" landed silently in Notification Centre and
    the user saw nothing — success and a dead grab were indistinguishable.

    Current scheme (`Notifier` executes, `BannerPlanner` decides — the planner is pure
    and unit-tested, because UNUserNotificationCenter only works in a signed,
    LaunchServices-launched bundle):
    - The **working** banner keeps one fixed identifier: on-screen updates replace in
      place, off-screen stage updates amend Notification Centre silently — both right
      for progress. Its body tracks the script's markers ("Reading the link…" →
      "Checking the post…" → "Saving to Downloads" / "Saving slide i of n…"), so it
      never claims a download that hasn't started.
    - While the carousel dialog is up (`::progress:prompt`) the working banner is
      **removed** — the dialog is the UI, and the removal is also what makes the re-post
      after the user's choice present as a new banner.
    - The **outcome** posts with a fresh UUID after explicitly removing the working
      banner and the previous grab's outcome. Fresh id ⇒ always presents; the removals ⇒
      no stacking, which was the (real) problem the same-id scheme was solving.
    - Cancel on the dialog is detected (`  cancelled.` on stdout →
      `GrabResult.cancelled`) and posts **nothing** — a deliberate act is not an outcome.

    "Post something immediately" still stands: until a banner appears, a slow grab and a
    hotkey that never fired are indistinguishable, and a silently-lost chord is a real
    failure mode (gotcha #14). The shell script keeps its own plain equivalent for the
    Shortcut path, still gated on `CARABINER_NO_NOTIFY` so the app never doubles up.

23. **`--newline` is what makes progress live — NOT `PYTHONUNBUFFERED`. This entry
    previously said the opposite, and that was measured wrong.** Corrected 2026-07-31.

    The claim recorded here was that yt-dlp block-buffers its piped stdout like any
    CPython process, so `PYTHONUNBUFFERED=1` on the yt-dlp call was load-bearing and
    without it every marker would land in one burst at exit. It is false. yt-dlp calls
    `out.flush()` on every progress write, so CPython's pipe buffering never gets a
    chance to apply. Measured against the **real bundled binary** through the exact
    `tee`/`grep` pipeline in `ig_video`, markers arrive at the same moments either way:
    with `PYTHONUNBUFFERED=1` **0.00 / 0.35 / 0.64 / 1.41 / 2.49 / 3.09s**, and with
    `env -u PYTHONUNBUFFERED` the same **0.00 / 0.35 / 0.64 / 1.41 / 2.49 / 3.09s**.

    **How the wrong fact got recorded, because that is the reusable part:** the original
    "1.7s of output delivered at t=1.7s" was measured against `test/test-progress.sh`'s
    own yt-dlp *stub* — a bare `python3 -c` loop that never flushed — not against yt-dlp.
    The stub buffered, the real tool does not, and the test dutifully confirmed a property
    of the test. A stub that differs from the tool in exactly the dimension under
    measurement will manufacture whatever conclusion you are looking for. The stub now
    flushes, like the tool it stands in for. (Reproduce the mechanism in ten seconds:
    three `sys.stdout.write` + `flush()` lines 0.3s apart, piped, with
    `env -u PYTHONUNBUFFERED`, arrive **0.31s apart**; drop the `flush()` and the same
    three arrive **0.02s apart**, i.e. all at exit.)

    **What is actually load-bearing is `--newline`.** yt-dlp writes its progress bar with
    `\r`, overwriting one line in place, and `grep --line-buffered` emits whole *lines*
    only — so a `\r`-only stream produces no line at all until EOF. Verified by deleting
    `--newline` while keeping `PYTHONUNBUFFERED=1`: **zero** discrete markers reach the
    app for the whole download, and the ring sits frozen and then snaps. That is the same
    symptom the old entry blamed on buffering, which is why the mis-attribution survived
    — both stories predict a frozen ring, and only one of them is the cause.

    `PYTHONUNBUFFERED=1` stays in `ig_video` anyway: it is free, and it is insurance
    against a future yt-dlp that stops flushing. It is defensive, not load-bearing, and
    the comment there says so. Do not delete `--newline` on the strength of it.

    `test/test-progress.sh` now checks the number of *discrete* marker lines (three), not
    just their presence: a substring check passes either way, because the `\r`-joined blob
    still contains `::progress:download: 50.0%` inside it. The liveness/spread check is
    kept — it is a true assertion about live delivery — but it was attributing the cause
    to the wrong mechanism. Both fail when `--newline` is removed (1 line, 0ms spread).

    **Scope, recorded so nobody reads the ring as broken:** only the Instagram video path
    reports download percentages. The YouTube, Pinterest and generic branches call yt-dlp
    as a single-shot command with no progress template and no `tee` pipeline, so the ring
    stays in `resolve` for the whole download and then jumps at `progress save`. That is
    an Instagram-first scope call, not a bug.

    A second, smaller tooth from the same change: `rc=$?` after
    `log="$(yt-dlp … | tee >(grep …))"` is correct, and `PIPESTATUS` is not needed.
    `set -uo pipefail` carries yt-dlp's status out of the pipeline, and `grep` lives in a
    *process substitution* rather than a pipeline stage — which is load-bearing, because
    `grep` exits 1 when it matches nothing (every image post), and as a real stage that 1
    would become yt-dlp's exit code and silently take gotcha #4's image fallback with it.

    **A pre-existing latent issue, found during this work's review — not introduced by
    it, and not currently reachable.** `ig_video` picks its downloaded file with
    `head -n1` of an alphabetical `ls "${tmp}".*`. If a per-format intermediate ever
    survives a successful merge (`.f140.m4a`, `.f399.mp4`), it sorts before the merged
    `.mp4` and would win. On the failure path the function returns before that lookup
    runs, so there is no live bug today — but the lookup is order-dependent in a way
    nothing guarantees, and is worth tightening the next time that function is touched.

24. **A button named "Cancel" never comes back as `button returned` — `display dialog`
    THROWS -128, and without a catch, Cancel silently meant "grab slide 1".** Found
    2026-08-02 from a user report. AppleScript auto-designates any button literally named
    "Cancel" as the dialog's cancel button, and clicking it raises error -128 ("User
    canceled") instead of returning: osascript exits 1 with nothing on stdout,
    `ask_slide_or_all` saw an empty answer, and its "dialog failed → safe default"
    fallback answered **slide** — so Cancel and "This slide" were the same button, and
    the `"Cancel")` case was unreachable dead code on the headless path. The heredoc now
    wraps the dialog in `try … on error number -128 → return "Cancel"`, pinned to -128
    specifically: any *other* osascript failure still comes out empty and takes the safe
    default, which is what a genuinely broken dialog should do. The osascript stub in
    `test/test-progress.sh` models the throw faithfully (it only answers "Cancel"
    cleanly if the submitted AppleScript carries the -128 catch) — a stub that just
    echoed "Cancel" would have hidden this bug forever, which is gotcha #23's stub
    lesson again. Check 10 there pins cancel-downloads-nothing.

25. **`cmd | grep -q PATTERN` under `set -o pipefail` fails when the pattern is FOUND.**
    Found 2026-08-10 writing `scripts/release.sh`'s preflight gate, before the first real
    release run. `grep -q` exits the instant it matches; the producer then writes into a
    closed pipe, takes SIGPIPE, and dies with 141. `pipefail` makes the *pipeline* report
    141 — so the idiom inverts: `codesign -dv "$f" | grep -q runtime || die` fires `die`
    on a correctly hardened binary and stays quiet on an unsigned one.

    All four gates in `release.sh` were written that way. Three would have rejected a
    perfectly good Release build with a nonsense message; the fourth,
    `assert_no_get_task_allow`, inverted into a **false negative** and would have waved a
    Debug build through to notarization — the exact thing it exists to stop (gotcha #16).

    The fix is to capture and match, never pipe:
    ```bash
    local out; out="$(codesign -dv "$1" 2>&1)"
    [[ "$out" == *"flags="*"runtime"* ]] || die "..."
    ```
    **Why it survived the first test run, which is the reusable part:** every gate was
    tested against a Debug build, where three of the four are *supposed* to fail. They
    failed, the tests went green, and the bug sat entirely on the untested match path. It
    took signing a throwaway binary with a real `--timestamp` — an actual positive case,
    not a fixture — to expose it. A gate tested only on inputs it should reject proves
    nothing about the inputs it should accept. `test/test-release.sh` now carries both
    directions for each gate; the positive one skips (rather than fails) when offline,
    since a secure timestamp needs Apple's TSA.

    This is a bash trap, not a codesign one, and `carabiner` runs under the same
    `set -uo pipefail`. Its five `grep -q` pipelines (lines 127, 261-262, 267, 365) are
    all safe, and it is worth knowing exactly why, because the reason is narrower than it
    looks: every one of them is fed by `echo` or `printf` of a short string, which is
    written in a single syscall and exits before `grep -q` can close the pipe. Verified
    in the same shell — `echo … | grep -qiE '^https?://'` returns **0**, while
    `seq 1 200000 | grep -q '^1$'` returns **141**. The safety comes from the producer
    being small and fast, not from anything structural. A future change that pipes a real
    command's output into `grep -q` there inherits this bug.

26. **`xcodebuild build` injects `get-task-allow` into RELEASE builds too — the injection
    is tied to the build *action*, not the configuration.** Found 2026-08-10 on the very
    first `scripts/release.sh` run, which died at its own preflight gate with "this is a
    Debug build" on an honest `-configuration Release` build. That message was right about
    the entitlement and wrong about the cause, which is the confusing part.

    Gotcha #16 says "notarize Release builds, never a Debug one" and implies choosing
    Release is sufficient. It isn't. `CODE_SIGN_INJECT_BASE_ENTITLEMENTS` defaults to YES
    and adds `com.apple.security.get-task-allow` whenever the action is `build`. Apple's
    intended path is `xcodebuild archive` + `-exportArchive`, where *export* strips it —
    so projects that always archive never meet this, and projects that build from the CLI
    meet it immediately. Verified on this repo:

    ```
    # -configuration Release, before the fix
    "com.apple.security.automation.apple-events" => true
    "com.apple.security.get-task-allow" => true
    ```

    Fix is one setting on the Release config, `CODE_SIGN_INJECT_BASE_ENTITLEMENTS: NO`,
    which lands in the same place as exportArchive without the `ExportOptions.plist`
    machinery. Our real entitlements are unaffected — they come from
    `CODE_SIGN_ENTITLEMENTS`, which this does not touch. After it, the Release build
    carries `apple-events` alone and preflight passes with 117 bundled Mach-Os hardened
    and timestamped.

    Keep the gate's wording in mind if it ever fires again: "this is a Debug build" is the
    *likeliest* cause of a stray `get-task-allow`, not the only one.

27. **"The application 'Carabiner' can't be opened" is a LaunchServices registration
    problem, not a broken build — and the app will run fine when you exec the binary
    directly, which is what makes it so confusing.** Hit 2026-08-12. `open
    ~/Applications/Carabiner.app` returned **exit 0** and nothing launched; Finder showed
    the generic "can't be opened" dialog. Everything you would normally suspect was fine:
    `codesign --verify --deep --strict` said *valid on disk / satisfies its Designated
    Requirement*, there were no quarantine xattrs, the architecture matched, and running
    `Contents/MacOS/Carabiner` directly started the app and logged
    `grab hotkey registered as ⌃⌥⌘V`. The decisive clue is that the **same bundle launched
    fine from `/tmp` and failed from `~/Applications`** — a location-dependent failure, so
    the bundle is not the variable.

    Cause: repeated dev installs to `~/Applications` had left **18+ stale records** for
    `com.offpiste.carabiner` in the LaunchServices database, and LS resolved that path to
    a dead one. This is gotcha #11's poisoning mechanism, just arriving as a launch
    failure instead of a notification failure. A Developer ID copy also sitting in
    `/Applications` (a different Team ID from the Apple Development dev builds) is what
    makes duplicate records accumulate in the first place.

    Fix, and it is instant:
    ```bash
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
      -f ~/Applications/Carabiner.app
    open ~/Applications/Carabiner.app
    ```
    Inspect the damage with `… /lsregister -dump | grep -i carabiner | grep -iE 'path|bundle id'`.
    The real prevention is gotcha #11's rule, which this is a second face of: **do not keep
    two copies of this bundle id on disk.** A Developer ID build in `/Applications` and an
    Apple Development build in `~/Applications` are two, and they fight.

    Related trap noticed in the same investigation, not the cause but worth knowing:
    reusing one `-derivedDataPath` for both `xcodebuild test` and `xcodebuild build`
    leaves the test host's `Contents/PlugIns/CarabinerTests.xctest` and its
    `XCTest`/`Testing` frameworks embedded in the app bundle, because the `build` action
    does not remove what the `test` action added. That bundle does launch, so it will not
    announce itself — but it is not the app you are shipping. Use a separate derived-data
    path for a build you intend to install, or accept that you are testing a test host.

28. **Safari's cookies need Full Disk Access, and nothing in the app can grant or even
    prompt for it.** Confirmed 2026-08-13, with Safari quit so its cookie file was flushed:

    ```
    carabiner -b safari -s 1 'https://www.instagram.com/p/<code>/'
    ERROR: [Errno 1] Operation not permitted:
      '~/Library/Containers/com.apple.Safari/Data/Library/Cookies/Cookies.binarycookies'
    ✗ download failed.
    ```

    **The control run is what makes that a diagnosis rather than a guess, and it is the
    part worth copying:** the *same URL* with `-b chrome` downloaded the file fine. So it
    is macOS denying the Safari cookie read — not a private post, not a bad URL, not a
    broken engine. Without that control, "Operation not permitted" on an unfamiliar path
    is indistinguishable from every other Instagram failure.

    Consequences, all built:
    - The Setup & Permissions window has a **Full Disk Access** row. macOS offers **no API
      to grant it and — unlike Automation — none to prompt for it either**, so the row can
      only *detect*, explain, and deep-link to
      `x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles`.
    - **Detect with `open()`, not `stat()`.** Measured by the reviewer on this machine:
      `stat` on that cookie file **succeeds** while `open()` returns `EPERM`. An existence
      check would therefore have produced a permanent false green — the one new row whose
      whole job is honesty. `LivePermissionChecker` opens the file and classifies the
      errno: `EPERM` → denied, success → granted, `ENOENT` → *not applicable* (Safari has
      never run; reporting that as denied invites a Chrome-only user to grant the broadest
      permission on macOS for nothing, and reporting it as granted is a tick with nothing
      behind it).
    - **Fallback:** on a Safari cookie-read failure `GrabRunner` retries once with Chrome's
      cookies — the control above is the proof that path works — and flags
      `usedFallbackBrowser` so the banner says so. A silent fallback would be lying by
      omission: a different browser can mean a different Instagram account.
    - The user-facing error names Full Disk Access explicitly.

    **Open, never tested:** whether macOS requires **quitting and relaunching Carabiner**
    for a fresh FDA grant to take effect in the already-running process. If it does, the
    row reads red immediately after the user grants it and needs a "quit and reopen" note.
    Nobody has checked.

29. **Safari sends a CORS preflight where Chrome does not — `GrabServer`'s `OPTIONS`
    handler is load-bearing for Safari alone.** Measured 2026-08-12 against a throwaway
    listener that dumped raw request headers, with the extension loaded unpacked in Chrome
    and converted for Safari. Chrome skips the preflight because
    `http://127.0.0.1:51847/*` is in `host_permissions`; Safari preflights anyway. Delete
    the `OPTIONS` handler as dead politeness and **Safari silently stops working while
    Chrome carries on fine** — the worst shape a bug can have, because the obvious test
    machine passes.

    The same measurement pinned the origins, which is why the gate is a *scheme* check and
    not an ID allowlist:

    ```
    Chrome → Origin: chrome-extension://ccngbaicbbcdhbppljflaagmbfpcjjcn   (the extension ID)
    Safari → Origin: safari-web-extension://dcea6524-ab56-4469-895f-d4f4e84f139e
    ```

    Safari's is a **per-install UUID** — it differs on every machine, so exact-ID
    allowlisting was never an option for Safari, whatever it may look like for Chrome.

    **Reasoned, not yet measured, and the reason this belongs here:** the preflight answers
    `204` for any path/method, with no `Access-Control-Allow-Methods` and no `Max-Age`. That
    works today only because `POST` and `content-type` are CORS-safelisted. Add **any**
    custom request header later — a pairing token is the obvious candidate — and Safari
    breaks silently while Chrome keeps working, exactly as above. If you add a header, fix
    the preflight in the same commit.

    Also earned here: **the MV3 service worker is ephemeral and Safari kills it when idle.**
    It vanishes from Develop → Web Extension Background Content mid-session, so any
    debugging procedure that depends on catching it in an inspector console is unreliable —
    the header measurement was only possible by making the worker fire its request at
    startup. It matters beyond debugging, because the worker holds the streaming connection
    for a whole grab. An in-flight `fetch` does reset the idle timer, but **that has not
    been re-checked against a genuinely long carousel.**

30. **Where the extension's JS runs decides both what it can call and what `Origin` it
    sends. Two different mistakes, one root cause, and the first is the answer most sources
    will give you.**

    **(a) A content script injected as a page `<script>` runs in the MAIN world, where
    `chrome.*` does not exist.** The plan for this feature specified exactly that — a
    `loader.js` that appended `<script type="module">` to escape the "content scripts can't
    use static `import`" limit. It does escape that limit, and it would have produced **no
    button at all, in either browser, with no visible error**: `chrome.runtime.sendMessage`
    and `chrome.runtime.onMessage` are bound only into the isolated world a content script
    runs in, so every click and every incoming progress message would have thrown. Caught in
    review before it shipped (it was never observed failing live — nobody built the broken
    version to watch it break). The working pattern, and the documented one, is a **dynamic
    `import()` of a web-accessible resource from a real content script**: it keeps you in
    the isolated world with `chrome.*` intact, at the cost of an async IIFE. The plan doc is
    annotated as superseded rather than deleted, because "inject a `<script type=module>`"
    is what most sources say and it will be proposed again.

    **(b) Only the service worker may call the app.** A `fetch` from the content script
    carries `https://www.instagram.com` as its `Origin` and the app **correctly rejects it**
    — that is gate 1 of gotcha #29 doing its job, not a bug to work around. Every outbound
    call goes through `chrome.runtime.sendMessage` to `worker.js`, which owns the only
    `fetch` in the extension. If a future change ever "simplifies" that by fetching from the
    content script, the whole access-control story collapses into "any instagram.com page
    can drive the app".

    **Still unknown and worth checking first if the button is missing:** whether dynamic
    `import()` from a content script survives instagram.com's CSP in the wild, and in Safari
    at all. The tests run under jsdom; only a real browser answers it.

31. **Instagram's post links are not all `/p/<code>/` — the profile grid uses
    `/<handle>/p/<code>/`, and a post page is full of `/p/<code>/c/<id>/` comment
    permalinks.** Found 2026-08-13, the moment real captured markup replaced the synthetic
    fixtures. `shortcode.js`'s regex was anchored at the path start, so it matched
    **nothing** on a profile grid: the button would never have appeared on any profile
    page. **100% broken, silently, against a fully green test suite** — because the
    fixtures were hand-written and encoded the same wrong assumption as the code they were
    testing. Swapping in real markup turned 42 green tests into 38 pass / 4 fail
    immediately.

    **The lesson is gotcha #23's stub lesson in a new costume: a fixture you authored tests
    your assumptions, not the world.** For anything that parses someone else's markup or
    output, capture the real thing. What worked for capturing it (Wisse, in Chrome's
    console): a one-liner that Blob-downloads `document.documentElement.outerHTML`.
    **`copy()` silently produced an empty clipboard** on ~32 KB of markup — do not use it
    for this.

    Measured facts about the real fixtures, so nobody "fixes" a correct count: the feed
    fixture yields **1** container, the profile grid **12**, and a permalink page **1** —
    not 13, even though that page carries a dozen comment permalinks for the same post,
    because they all dedupe into the one `<article>`. (An earlier "8 thumbnails" reading of
    the grid was a `/p/`-only query; the other four tiles are `/reel/`.) The tests over
    this were **mutation-checked** rather than trusted: reverting the anchored regex fails
    8, reverting the prefix selector fails 2, dropping the article dedup fails 4.

32. **Two XcodeGen behaviours will each cost you an afternoon on a Safari appex, and
    neither announces itself.** Both hit 2026-08-13 while adding
    `CarabinerSafariExtension`.

    - **An `info:` block ALWAYS regenerates that target's `Info.plist` from `properties`,
      silently discarding a hand-written file at the same path.** The appex's `NSExtension`
      dictionary simply vanished. Confirmed by running `xcodegen` and watching it go. So
      either the whole plist lives in `project.yml`, or the target has no `info:` block at
      all — there is no "generate the basics and keep my additions".
    - **A `type: folder` reference copies the folder under its OWN name**, one level deeper
      than you meant. `../extension/dist/chrome` as a single folder reference put the
      manifest at `Contents/Resources/chrome/manifest.json`. **Safari will not load an
      extension whose `manifest.json` is not at the resource root, and nothing in the build
      says a word about it.** The fix is three entries — `manifest.json` as a file, `src/`
      and `icons/` as folder references — so the manifest lands at the root while the
      subdirectories its own relative paths refer to stay real directories. This is the
      same mechanism that puts `.deps/bin`'s *contents* at `Resources/bin/`; there it was
      the behaviour we wanted, which is exactly why it is easy to walk into here.

    Verify from the **built bundle**, never from the yml: manifest at the `Resources` root,
    every manifest-referenced file present, and the appex hardened
    (`codesign -dv` → `flags=0x10000(runtime)`).

33. **A timeout must mean "no news", never a verdict — and "pause the timer" silently means
    "no timer". This bit twice on the same day (2026-08-13), in two different components,
    in two different ways.**

    - **The app's connection deadline (`GrabServer`).** The carousel dialog can wait on a
      human indefinitely, so the 600s deadline was made to *pause* on `::progress:prompt`. The
      re-review walked the event sequences: `[prompt]` followed by **no further event** left
      the deadline permanently unarmed, reinstating the file-descriptor leak the deadline
      existed to prevent. Replaced with a finite **3600s backstop**. *A bound you relax must
      stay a bound.*
    - **The button's watchdog (`extension/src/grabTracker.js`).** The first version was
      **terminal**: on timeout
      it deleted the grab from the tracking map, so a late real outcome was dropped and a
      long *successful* grab ended permanently amber. Reachable on three ordinary paths in
      our own engine, traced not theorised: ffmpeg's silence during a re-encode (gotcha #21
      measured 12.3s per 45s of video), gallery-dl emitting nothing after its first marker,
      and the carousel dialog. That is **worse than the bug it replaced** — it misinforms
      rather than under-informs. Now the amber state means "no news yet": a late `progress`
      restores the ring, a late `done` corrects to a tick, and the dialog genuinely suspends
      the watchdog. The 90s threshold is justified in the source against gotcha #21's
      measured encode rate — 90s of silence covers roughly 5.5 minutes of source video
      being re-encoded. Verified by driving the
      *shipped* `grabTracker.js` with real timers outside the implementer's own harness.

    When you write a timeout, finish the sentence "…and keep listening". If you can't, it
    is a verdict, and it will be wrong sooner than you think.

34. **A pure helper can be 100% tested while the CALL SITE that is supposed to use it is
    not — the bug lives in the wiring, and helper-only tests cannot see it.** Found
    2026-08-13, and *proved*, which is the point. The onboarding row read
    `lastSeen[.chrome]` — hardcoded — so a Safari user's check-in was never read and the
    row stayed grey forever, on a row that exists for Safari. The fix added a pure
    `mostRecentBrowserCheckIn(_:)` plus tests. The reviewer then **mutated the call site
    back to the hardcoded bug and watched all 199 tests still pass**: on a revert the
    helper just becomes dead code, with no failure and no warning. That is the same gap
    class that let the original bug ship.

    The rule: **ask "would this test fail if the fix were reverted?" — and then actually
    revert it and look.** The regression guard here was re-verified twice, independently:
    the implementer reverted and saw red, and the re-reviewer repeated the whole mutation
    itself rather than trusting the report.

    Two neighbours from the same pass, same family:
    - **Tests that pass when the code under test is deleted are theatre.** The first
      persistence tests did exactly that; they were replaced with tests of the real
      functions, including garbage input. "Untestable because it touches `UserDefaults`"
      was also avoidable — a static taking a `UserDefaults` instance made it trivial.
    - **Know where your tests stop having teeth.** `GrabServerTests` pins the pure decision
      layer only; reverting `accept()`'s backstop *wiring* while leaving `deadlineAction`
      intact would still pass every one of them. The file's own header says the I/O half
      is not covered — say so where the tests live, rather than letting a green count
      imply more than it means.

35. **pkd silently refuses an unsandboxed appex — the App Sandbox requirement is on the
    APPEX, not the app, and the two do not constrain each other.** Found 2026-08-16, the
    first time a human looked for the extension in Safari's Extensions list: it simply
    wasn't there. No error in Safari, nothing in the build, `pluginkit -a` returns
    success-shaped silence and registers nothing. The one place the truth appears is
    pkd's own log:

    ```
    pkd: rejecting; Ignoring mis-configured plugin at [...CarabinerSafariExtension.appex]:
    plug-ins must be sandboxed
    ```

    The diagnostic that finds it:
    ```bash
    /usr/bin/log show --last 5m 2>/dev/null | grep -i CarabinerSafariExtension
    pluginkit -m -v | grep -i carabiner   # registered at all?
    ```

    The design had flagged "Apple's converter template sandboxes these, and Carabiner
    cannot be sandboxed — it shells out to yt-dlp/ffmpeg and writes `~/Downloads`" as the
    top risk. That fear was aimed at the wrong bundle: a process is governed by its own
    signature (gotcha #20's isolation, from the other direction), so the **appex** carries
    `com.apple.security.app-sandbox` (+ `network.client`, matching Apple's template) in
    `app/CarabinerSafariExtension/CarabinerSafariExtension.entitlements`, and the **app**
    stays unsandboxed and keeps shelling out. Sandboxing the appex costs nothing here
    because it is a thin wrapper: the extension's `fetch` to `127.0.0.1:51847` runs in
    Safari's extension processes, not the appex. Verified both directions on this machine:
    pluginkit refused the identical appex without the entitlement and lists it with it,
    and the sandboxed-appex app still grabs and serves `/health`.

36. **Writing into Instagram's DOM breaks INSTAGRAM, not the extension — the page's tree
    is React-hydrated and must be treated as read-only.** Found 2026-08-17 from a user
    report that read as "Instagram is tripping": skeleton feeds that never rendered,
    grids misrendering under fast scroll, a post modal that would not respond. The
    extension looked innocent — every symptom was in *Instagram's own UI* — and the
    conviction came from a 20-second A/B only a user can run: extension off → flawless,
    on → broken. The mechanism: `attach()` did `container.appendChild(host)` and set
    `container.style.position = "relative"` inside React-owned elements; Instagram
    server-renders and hydrates, foreign nodes mid-hydration are a mismatch (their
    console shows **minified React error #418** — the fingerprint to grep for), and
    React's recovery is what shredded the page. It had *worked* on 2026-08-16 —
    hydration races are timing-dependent, so "verified working yesterday" is no defence.

    The fix is structural, not probabilistic: all buttons live in one
    `<carabiner-overlay>` off `documentElement` (beside `<body>`, outside anything React
    hydrates), `position:absolute` (it was `fixed` until 2026-08-20 — gotcha #41 explains
    why that changed), placed over posts by `getBoundingClientRect` geometry —
    repositioned on scroll (capture:true — Instagram scrolls inner elements)/resize/
    mutation, rAF-coalesced, never a free-running loop (battery, and it held the test
    process open forever). Dedup is a Map keyed by container element, which surfaces the
    recycling trap: a virtualized list reuses DOM nodes for different posts, and a stale
    element→button mapping downloads the WRONG post. `attach()` rebinds on permalink
    change; `content.test.js` pins both this and the "never write to the page" invariant
    (mutation-checked: one re-added `appendChild` fails it).

    Two debugging lessons from the same afternoon, cheaper to reuse than re-earn:
    - **An SPA keeps orphaned content scripts alive for days.** Every extension reload
      orphans the previous injection in every open Instagram tab, and those tabs keep
      running stale code across all in-page navigation. Symptoms reported from long-lived
      tabs tell you about OLD code; only a fresh tab tells you about current code.
    - **Statically-declared content scripts are snapshotted at extension load; dynamically
      `import()`ed modules are re-read per page load** (unpacked install). So a
      `containers.js` edit goes live on page reload, but a `content.js` edit needs the
      extension ⟳ — an edit that "didn't take" may just be the half that needs the reload.

37. **macOS "grant Full Disk Access" is not a permission the app can be caught mid-way
    through — macOS forces the relaunch itself. And the one API in this window that CAN
    fail silently is the Safari one, because its error is optional and we were discarding
    it.** Both settled 2026-08-17, closing the sharpest open question in the onboarding
    window.

    - **FDA (checklist item 13).** The fear was that a fresh grant would not reach the
      already-running process, leaving the row red right after the user turns it on and
      needing a "quit and reopen Carabiner" note. The grant indeed does not reach a running
      process — but the toggle offered **only "Quit & Reopen"**, no "Later", so macOS
      performs the relaunch as part of granting. After it (pid 87789 → 89252) the row read
      green. **No note is needed.** The green was then checked against gotcha #28's
      false-green trap rather than trusted: a real `POST /grab` with `browser: safari`
      landed 2 files with `::progress:from:@off__piste` in one clean stage sequence, and
      since `shouldRetryWithChrome` only fires on a *failed* Safari attempt — which would
      replay the stages and re-show the carousel dialog — the absence of a replay is the
      proof no Chrome fallback happened.
    - **`SFSafariApplication.showPreferencesForExtension` (item 15).** Its signature is
      `(withIdentifier:completionHandler:)` with the handler defaulting to nil, so the
      obvious one-argument call **throws the only error channel away**. It failed on its
      first real run — Safari's settings never appeared, System Events showed Safari with
      one window ("Instagram"), nothing logged anywhere — and looked exactly like a broken
      extension. With a handler attached it reports success 3 for 3. Never call this API
      without the handler; a row's Allow button that silently does nothing is the worst
      shape this window can fail in. The identifier it takes must equal the appex's
      `PRODUCT_BUNDLE_IDENTIFIER` in `app/project.yml`, coupled by nothing but a comment.
    - **Two other things seen here, recorded so they are not re-investigated blind.**
      Safari's Installed list can show **two identical enabled "Carabiner" entries** while
      `pluginkit -m -A -v` reports exactly one plug-in and one appex exists on disk — so it
      is Safari-side state, not a double registration (prime suspect: the "Share across
      devices" checkbox syncing extension records via iCloud). And
      `chromewebstore.google.com/detail/PLACEHOLDER_ID` does **not** 404 — it redirects to
      the Web Store home page, so the unreplaced placeholder presents as a cheerful
      "Welcome to the Chrome Web Store" rather than an error.

    Two instruments from this session worth reusing, since both replaced a question to the
    user with a measurement: System Settings' deep links are verifiable from a shell —
    `open "x-apple.systempreferences:…?Privacy_AllFiles"` then read the window title via
    System Events, which returns literally `Full Disk Access` (item 14, no human needed).
    And `lastSeen` persistence is only honestly testable once you know the extension pings
    `/health` **solely** on `onInstalled`/`onStartup`: an app restart cannot trigger a
    check-in, so identical timestamps either side of one prove the green row came off disk
    (item 16) rather than from a fresh ping.

38. **Chrome sends NO `Origin` header on a simple GET from an extension service worker —
    so every origin-gated GET is 403 forever, and `/health` was one.** Found 2026-08-18
    fixing item 11's cold launch. Measured in Chrome's own worker console, against a
    running app:

    ```
    GET  /health?browser=chrome                          → 403
    POST /health?browser=chrome (content-type: json)     → 200
    ```

    The cause is the flip side of gotcha #29: `host_permissions` lets Chrome bypass CORS
    entirely for these requests, and a request that never goes through CORS has no
    `Origin` attached. `POST /grab` works only because `content-type: application/json`
    makes it a *non-simple* request. So the rule is **not** "extension fetches carry an
    Origin" — it is "non-simple extension fetches do".

    Two live consequences, both silent, both shipped:
    - The cold-launch probe polled `GET /health` for 120 seconds against an app that was
      up **2 seconds in**, and could not have succeeded at any timeout.
    - `ping()` — the check-in that turns the onboarding window's browser row green — used
      the same bare GET, so **it has never once reached the app from Chrome**. Only
      Safari's row was ever verified, and Safari sends an `Origin` (it preflights), which
      is exactly why this survived review.

    Both now use one `health()` helper with `/grab`'s own request shape. Do **not** "fix"
    a future case of this by adding a custom header to a GET: that works in Chrome and
    silently breaks Safari, whose preflight advertises no allowed headers (gotcha #29
    again, same file, same trap).

    **The debugging lesson is the expensive part.** `curl` got 200 while the extension got
    nothing, and three rounds went into worker-termination and hung-socket theories —
    both consistent with every symptom, both wrong — before anyone compared the two
    *requests*. When a shell client works and the browser client does not, the requests
    differ; diff them before theorising about lifetimes. Two instruments also lied on the
    way, and neither announced it:
    - **An open DevTools console keeps an MV3 service worker alive**, so it cannot observe
      a worker-termination bug — it prevents it. Any "it works with the console open"
      result is about the console, not the code.
    - A `chrome.storage` trace added to see past that was **inert**: the manifest lacked
      the `storage` permission and the write sat inside a silent `catch`. It looked like
      evidence of nothing happening; it was evidence of nothing being recorded. Verify an
      instrument before trusting a run made with it, and never let a diagnostic swallow
      its own errors.

    Also settled here, since it looked like the bug twice: Chrome's "Open Carabiner?"
    external-protocol dialog is **tab-modal**, so a launch tab created `active: false`
    shows nobody a prompt, and closing that tab cancels the pending handoff. The launch
    tab must be visible and must survive until the app answers.

39. **A test that loads a module differently than the app does cannot see whole classes of
    bug — `new Function(source)` does not care whether the file has `export`.** Found
    2026-08-19 adding `extension/src/actionBar.js`. The file was written in the classic
    style of `ndjson.js` (plain `function` declarations, no exports), but `content.js`
    loads it with `await import(chrome.runtime.getURL(...))`. So both functions came back
    **undefined**, `place()` threw inside a `requestAnimationFrame` callback — silently,
    because nothing in this extension is allowed to throw into the page — and the button
    would simply have stayed in its old corner with no error anywhere.

    Eight unit tests over that file were green throughout. They extracted the functions
    with `new Function(readFileSync(...))`, exactly as `ndjson.test.js` does for a file
    that genuinely is classic. That extraction ignores module syntax entirely, so it can
    never fail on a missing `export`. **The test was loading the file in a way the app
    never does.** The rule: extract with `new Function` ONLY for files the app also loads
    as classic scripts (`importScripts` — `ndjson.js`, `browser.js`, `launch.js`); import
    real ES modules the same way `content.js` imports them (`shortcode.js`,
    `containers.js`, `grabTracker.js`, `slideIndex.js`, `actionBar.js`).

    This is gotcha #23's stub lesson and #31's fixture lesson in a third costume, and the
    family resemblance is the point: **whenever a test differs from production in the exact
    dimension under test, it will confirm whatever you hoped.** A stub that does not flush,
    a fixture you wrote yourself, a loader that ignores exports.

    What actually caught it was a *wiring* test — the first test placement has ever had
    (`content.test.js`). Two smaller things learned there, both worth reusing:
    - jsdom has **no layout**: every `getBoundingClientRect()` is zeros, so anything
      geometric must be driven by stubbing rects per element. This is why `actionBar.js`
      finds Save by DOM structure rather than by grouping buttons into rows visually — a
      geometric rule would have been untestable and verified only by eye.
    - jsdom **does** round-trip `style.transform`, but omits it from `cssText`. A probe that
      prints `cssText` therefore shows the property missing and invites a completely wrong
      diagnosis (it cost one here — "jsdom drops transform" was asserted, then measured
      false a minute later).

40. **`SMAppService.mainApp.status` is `.notFound` BEFORE the first registration — treat it
    as "not registered yet", not as an error, or registration becomes unreachable.** Found
    2026-08-19 building the Launch at login row. Toggling it opened System Settings and did
    nothing; Carabiner never appeared under "Open at Login".

    The cause was our own status mapping, not macOS. `.notFound` was mapped to `.denied`,
    on the reasoning that a state we do not understand must never render as a tick. That
    reasoning is right and the mapping was still wrong: `.denied`'s action is "Open System
    Settings", so the toggle deep-linked to a pane Carabiner was not listed in, and
    **`register()` was never called even once.** The one action that would have revealed
    whether registration works was unreachable behind a defensive branch.

    `sudo sfltool dumpbtm | grep -i carabiner` is the decisive instrument: it prints
    macOS's Background Task Management records, and **empty output means no record at all**
    — which rules out `.requiresApproval` (that state requires a record) and leaves
    `.notFound`. Note it needs root, so it is a command to hand to the user, not to run.

    `.notFound` now maps to `.notDetermined`: still not a claim of success, but the toggle
    genuinely calls `register()` and the row re-reads the real status afterwards. Measured
    immediately after the change: `before=notFound threw=no after=enabled`, the row turned
    green, and the item appeared in Login Items & Extensions.

    The general lesson, which is the reusable part: **a dead end is not more honest than an
    attempt.** Refusing to act on an unknown state protects you from a false tick, but it
    also destroys the evidence you would need to understand the state — and it presents to
    the user as a button that does nothing, which is this project's worst failure shape
    (gotcha #37). Prefer "try, then report what actually happened".

    Two smaller facts from the same work: the login-item deep link is
    `x-apple.systempreferences:com.apple.LoginItems-Settings.extension` (verified by
    reading the window title back — it returns `Login Items & Extensions`), and the
    "Open at Login" list is at the TOP of that pane, above "Extensions", which is easy to
    scroll past when checking whether registration worked.

41. **An overlay that escapes the page's DOM inherits three problems the page used to solve
    for you: occlusion, scrolling, and stacking. All three arrived as user reports within
    36 hours of each other (2026-08-19/20), and none of them is a z-index bug.** Gotcha #36
    moved every button out of Instagram's React tree into a `<carabiner-overlay>` on
    `documentElement` at `z-index:2147483000`. That was right and must stay. What it also
    did — invisibly — was opt out of everything the browser does for an element that lives
    where it is drawn.

    - **Occlusion.** `place()` judged visibility from the container's own geometry: big
      enough, and intersecting the viewport. Open a post from a profile grid and the grid's
      anchors stay connected, sized and in-viewport *behind* the modal, so every tile's
      button stayed "visible" — and an overlay deliberately ranked above anything Instagram
      can draw paints them **on top of the open post**. Fixed by also requiring that no
      `[role=dialog]` rect overlaps the container. The rule is **occlusion, not "a dialog
      exists"**: Instagram keeps small `role=dialog` furniture around (the messages panel,
      the `...` menu), and hiding every button whenever any of them opens would make the
      button vanish with no visible cause — this project's worst failure shape (gotcha #37).
      A zero-size dialog is skipped for the same reason.
    - **Self-occlusion, the trap inside the fix.** A dialog occludes what is BEHIND it,
      never what is INSIDE it. The post modal's own button is inside the modal and overlaps
      it by definition, so the rule above hides it instantly and silently unless occluders
      that `contains()` the container are skipped. Adding a button to the modal (below) and
      the occlusion rule are therefore *coupled*: neither is correct alone.
    - **Scrolling.** Reported as "the icon is moving a bit later than the actual site".
      Structural, and no amount of rAF scheduling fixes it: Instagram scrolls on the
      **compositor thread**, while a viewport-positioned overlay only moves when
      main-thread JS runs, so it is permanently catching up. The fix is to stop positioning
      in viewport space — the overlay and its hosts are `position:absolute` and `place()`
      adds `window.scrollX/scrollY`, anchoring in **document** coordinates. `<html>` is
      unpositioned, so the containing block is the initial containing block at the document
      origin. Window scrolling then changes the viewport rect and the scroll offset by the
      same amount, the sum is unchanged, nothing is written, and there is nothing to lag —
      the browser carries the button, on the compositor. Everything *above* the conversion
      still reasons in viewport space, which is correct: the in-viewport test, the size test
      and the occlusion test all want viewport rects. Inner scrollers still need the
      main-thread correction they always had, which is why the scroll listener stays
      `capture:true`.
      **Do not "tidy" either element back to `position:fixed`.** That applies a
      document-space transform in viewport space and parks the button hundreds of pixels off
      on a scrolled page — much louder than the lag it replaced, and pinned by a test.

    **Also settled here: the post modal has a button again, reversing 8c59ddc.** That
    exclusion was correct when written — placement was corner-only, and the modal's
    `<article>` spans essentially the viewport, so "the container's top-right" was the
    top-right of the SCREEN, landing on Instagram's close X and making the post
    impossible to close. `actionBar.js` (2026-08-19) changed the premise by anchoring
    beside Save, which the modal has. The corner fallback survives for unrecognised markup
    and drops `DIALOG_CORNER_DROP` (56px) inside a dialog to clear the X — one rule
    everywhere, and a markup change demotes the position rather than removing the button.
    Deciding *what can have a button* (`containers.js`) and *whether it is visible*
    (`place()`'s occlusion test) are now cleanly separate jobs; the old exclusion conflated
    them.

    **The general lesson.** Each of these reads like a CSS or z-index problem and none of
    them is. Leaving the page's DOM buys structural safety from React (gotcha #36) and
    silently hands you the page's own responsibilities: what covers what, what moves when,
    and what is drawn on top. Expect the next one to arrive the same way — as a user report
    that sounds cosmetic.

    All three verified in a real browser by Wisse (Chrome, 2026-08-20) — which also
    retired the risk flagged at the time: `findSaveButton` does pick the modal's action bar
    and not a comment's like button, despite the comment list preceding it in DOM order.

42. **Reinstalling the app under a running Safari silently kills cold launch — Safari
    drops `carabiner://` navigations with no prompt, no error, and no log line.** Found
    2026-08-21 from a user report ("when the app is not active, it doesn't download on
    Safari — it worked before"). Nothing in the code was wrong: the appex was registered,
    shipped current extension code, buttons worked, and grabs completed whenever the app
    was already running. Only the cold-launch leg was dead, and only in Safari.

    The state that produced it was the morning's reinstall. The app bundle was replaced
    at 14:03, Safari started at 14:05, and the new appex's pluginkit registration landed
    at 14:09 — so that Safari session bound its extension state against a mid-swap
    snapshot. Around it, gotcha #27's rule was being violated three ways at once:
    LaunchServices held **nine** registrations for the `carabiner://` scheme (six aimed
    at deleted paths), three stale Debug builds still existed in `/tmp`
    (`carabiner-test`, `carabiner-test-dd`, `carabiner-dd`), and the `/Applications`
    Developer ID copy had been deleted out from under its own LS record. In that state a
    Safari tab navigating to `carabiner://launch` did nothing at all — the launch tab
    opened and no "open Carabiner?" prompt ever appeared — while `open carabiner://launch`
    from a shell launched the correct app fine. A scheme that resolves for `open` proves
    nothing about Safari.

    What fixed it, in order, with the causality measured rather than assumed:
    - Deleting the stale `/tmp` bundles, `lsregister -u`-ing every dead record, and
      `lsregister -f`-ing the real app left exactly one claim on the scheme — and Safari
      **still** silently dropped the navigation. Registry cleanup alone is not the fix.
    - Quitting and reopening Safari against that clean state fixed it: same click, app
      launched, file landed. (Untested: whether a restart against the dirty registry
      would also have worked — the cleanup came first and there was no way to un-clean.)

    The rule this adds to gotcha #27's family: **the appex swap happens under a running
    Safari session, so after any rebuild-and-reinstall of `Carabiner.app`, quit and
    reopen Safari before trusting anything Safari-side** — especially cold launch, which
    is the one leg with no error surface anywhere: not in Safari, not in the worker (the
    tab is created successfully), not in the unified log (WebKit keeps the scheme
    decision private; a targeted `log stream` during a real click captured nothing).
    Chrome is unaffected — its external-protocol dialog goes through Chrome's own
    machinery, not a Safari session's cached binding.

    Diagnostic shape worth reusing: reproduce the browser's half without the extension
    (`osascript` → Safari `make new document` at `carabiner://launch`) and compare it
    against `open` of the same URL. The AppleScript navigation matched the real button's
    failure exactly — "new tab, no prompt", confirmed by the user against the real button
    — which pinned the break inside Safari's scheme handling and cleared the extension,
    the appex, LaunchServices resolution, and the app itself in one move.

## Dependencies

- `yt-dlp` — video (IG/YouTube/etc.)
- `ffmpeg` — the re-encode/remux step
- `gallery-dl` — images + full carousels (fixes gotcha #4)

The carousel prompt ("just this slide or the whole set?") is a plain native macOS
dialog (`osascript display dialog`) — the *dialog itself* stays the stock native one
deliberately (see gotcha #9), but it is no longer unbranded: it carries the OFF-PISTE
logo from `assets/Carabiner.icns`. See gotcha #9 before "improving" the dialog engine.

## Conventions

- Bash, macOS/zsh target. Keep it dependency-light beyond the three tools above.
- Deterministic filenames from shortcode; `_fixed` for re-encoded video; `_sN` for a
  specific slide; `_silent` for audio-stripped.
- `-y` on ffmpeg to overwrite cleanly; clean up temp files after.
