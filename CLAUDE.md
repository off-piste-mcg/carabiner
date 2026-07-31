# CLAUDE.md — Carabiner

**Carabiner** — a small, trustworthy piece of kit that clips onto media and holds it.
A **local** macOS tool: paste/share a URL → clean, QuickTime-openable file in `~/Downloads`.

Read this first. It captures the built tool plus the non-obvious gotchas discovered the
hard way — treat "Known gotchas" as settled fact, not theory to re-test.

## What this project is

A local macOS tool that takes a pasted URL (Instagram first; YouTube / Pinterest
secondary), auto-detects image vs video, handles carousels (all slides OR one specific
slide via `img_index`), and saves clean files.

**Two front ends, one engine.** The bash `carabiner` script does all the grabbing; both
front ends just call it.

1. **`Carabiner.app`** (`app/`) — the native menu-bar app. **This is the primary UX going
   forward.** Open a post → ⌃⌥⌘V → file in `~/Downloads` + a branded notification.
   Currently dev-machine only: distribution needs Developer ID signing (spec phase 4).
2. **The macOS Shortcut** — the zero-install fallback for anyone who doesn't want the app,
   and how the tool shipped originally. Stays supported.

They **cannot share a hotkey** — a global chord has exactly one owner (gotcha #14). If a
teammate installs the app, they unbind the Shortcut's hotkey, or vice versa.

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
- **`setup.sh`** — installs the three deps via Homebrew, links `carabiner`/`clip`/`crab`.
- **`README.md`** — team setup + the macOS Shortcut wiring.
- **Shipped:** public repo at `github.com/off-piste-mcg/carabiner` (clone + `./setup.sh`).
  The macOS Shortcut is shared as an **iCloud link** in the README
  (`icloud.com/shortcuts/1633ebc20bf04369a20ccab25b38dc8b`) — one-click add, then each
  user sets their own hotkey (keyboard shortcuts aren't stored in a shared shortcut).
  The shortcut's Run Shell Script uses a portable one-liner so it finds `carabiner` on
  both Apple Silicon (`/opt/homebrew`) and Intel (`/usr/local`).
- **`app/`** — **`Carabiner.app`, the native Swift/AppKit menu-bar app (Phase 1 done).**
  Menu-bar only (`LSUIElement`), OFF-PISTE logo status item, global ⌃⌥⌘V hotkey. The status
  item and the notification use *different* assets: the menu bar draws the `StatusIcon`
  vector asset (the SVG, template-rendered so macOS tints it to the bar), while the branded
  notification keeps the full-colour `AppIcon` — `UNUserNotificationCenter` always takes its
  icon from the bundle icon, so the two never need to match. Reads the
  front browser tab via AppleScript, shells out to this repo's `carabiner` script, and
  posts a **branded** notification with the filename (or "N files"). Swift owns the
  experience; bash still owns the grabbing — the app never re-implements the pipeline.
  While a grab runs, the status item draws a progress ring around the mark (which shrinks
  to 10pt for the duration) — driven by `::progress:` markers the script writes to stderr,
  not by a guess. See `docs/superpowers/specs/2026-07-31-menu-bar-progress-ring-design.md`.
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

**Where things are:** `carabiner` (the engine, bash, repo root) · `app/` (the Swift app)
· `test/` (offline shell tests, no network — `test-path.sh` covers the `CARABINER_BIN`
resolution order, `test/test-progress.sh` covers the progress markers offline (stubbed
tools via `CARABINER_BIN`, no network)) · `scripts/` (`deps.lock` + `fetch-deps.sh`, the
pinned fetch for the bundled binaries) · `.github/workflows/build-deps.yml`
(manual-dispatch CI that builds the bundled ffmpeg/gallery-dl — see "Where we are /
what's next") · `docs/superpowers/specs/` (design) · `docs/superpowers/plans/`
(implementation plans) · `files/` (historical reference only, not part of the tool).

**Building the app with bundled binaries** needs one extra step before `xcodegen`, and it
is idempotent so it costs nothing to re-run:
```bash
./scripts/fetch-deps.sh   # ~42 MB on a cold run, then "✓ (cached)" forever
```
Skip it and you get a perfectly working app that quietly uses Homebrew instead — which is
the whole failure mode gotcha #17 exists to warn about, so check `Resources/bin` is
actually populated before concluding bundling works.

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
`grab hotkey fired`, `grabbing <url>`, `grab succeeded — <file>`). Those are `NSLog`, so
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

**Verifying a grab worked — do NOT trust timestamps.** gallery-dl preserves Instagram's
original mtime *and* birth time, so a freshly downloaded image can be dated weeks ago and
`ls -lt` / `find -newermt` will not show it. Videos differ (ffmpeg re-encodes, so they get
a real time), which makes the trap worse. Snapshot filenames and diff:
```bash
ls -1 ~/Downloads > /tmp/before.txt   # …grab…   then:
ls -1 ~/Downloads | diff /tmp/before.txt - | grep '^>'
```

## Where we are / what's next

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

22. **The app posts one notification per grab, not two.** `Notifier` posts "Grabbing…"
    immediately (before reading the tab, since AppleScript is part of the wait) and the
    outcome re-uses the **same identifier**, so it replaces that banner in place. A fresh
    UUID per banner — the obvious way — leaves both stacked in Notification Centre and a
    stale "Grabbing…" outliving the grab it described. The shell script does the
    equivalent for the Shortcut path with a plain banner, still gated on
    `CARABINER_NO_NOTIFY` so the app never doubles up. This matters beyond polish: until
    something appears, a slow grab and a hotkey that never fired are indistinguishable,
    and a silently-lost chord is a real failure mode (gotcha #14).

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
